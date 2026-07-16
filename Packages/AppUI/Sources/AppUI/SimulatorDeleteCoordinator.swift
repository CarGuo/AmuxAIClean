import Foundation
import ScanKit
import LogKit

/// v1.7 M1 PR-9：Simulator 系统管理卸载协调器（独立于 SwiftUI，便于单测）。
///
/// 设计动机：
/// - Simulator 设备与 Runtime 是 CoreSimulator 管理的资源，不能伪装成普通文件送进废纸篓；
/// - 系统管理卸载是**不可撤销**操作（设备数据或 Runtime 会被系统移除），必须有一套
///   独立、可测的协调层；如果直接堆进 ViewModel 会让 sheet 状态机和执行逻辑深度耦合，
///   也无法在不起 SwiftUI 上下文的情况下单测 allowlist / Simulator-running guard / 部分失败汇总。
///
/// 三段式执行：
/// 1. **prepare**：对选中 hits 做预检——Simulator 运行中 → 直接 `.blockedSimulatorRunning`；
///    无受管 UUID → `.invalid`；其他 → `.ready(plan)`。
/// 2. **confirm**：UI 侧在同一 sheet 内完成复核与不可撤销确认，本协调器只提供冻结计划；
/// 3. **execute**：对 plan 中每条 item 逐个调 SubprocessExecutor，并发布逐项状态；
///    用户请求停止时只停止后续未提交项，绝不强杀正在执行的系统卸载。
///
/// 与 [SubprocessExecutor] 的契约：
/// - 协调器拼出的 args 一定形如 `argsPrefix + [tailArg]`（如 `["simctl", "delete", <UDID>]`），
///   执行器内层 allowlist 校验做最后兜底——任何 tailArg 都不能突破 allowlist 既定的命令前缀。
/// - 生产调用方必须注入 `.waitUntilExit`；查询 timeout 不适用于正在提交的系统卸载。
///
/// 与 ViewModel 的边界：
/// - 协调器**不持有** @Published / SwiftUI 状态——只暴露纯函数 + struct 结果；
/// - ViewModel 消费逐项事件并只移除成功 rows，不触发无关卡片全量重扫。
public struct SimulatorDeleteCoordinator: Sendable {

    /// 一条待执行的 Simulator 系统管理卸载项。
    public struct Item: Sendable, Hashable {
        /// 关联卡的稳定 ID，用于失败时回写哪张卡的 hits 还需保留。
        public let cardID: String
        /// hit 自身 ID（= url.path），ViewModel 用来从 selected set 中移除已成功项。
        public let hitID: String
        /// 用户可读名（如 "iPhone 16 · UDID..."），用于 sheet 列表与失败 alert。
        public let displayName: String
        /// 类型化资源种类。生产仅允许 Device 与 Runtime 两种，避免重新退化为任意命令。
        public let kind: ManagedUninstallRecipe
        /// 扫描器报告的占用估算，用于确认 sheet 展示；不参与命令拼接。
        public let sizeBytes: Int64?
        /// 完整可执行路径（如 `/usr/bin/xcrun`）。
        public let executable: String
        /// 完整 args（已 append tailArg），如 `["simctl", "delete", "<UDID>"]`。
        public let args: [String]

        public init(cardID: String,
                    hitID: String,
                    displayName: String,
                    kind: ManagedUninstallRecipe = .simulatorDevice,
                    sizeBytes: Int64? = nil,
                    executable: String,
                    args: [String]) {
            self.cardID = cardID
            self.hitID = hitID
            self.displayName = displayName
            self.kind = kind
            self.sizeBytes = sizeBytes
            self.executable = executable
            self.args = args
        }
    }

    /// `prepare` 的产物。
    public enum Plan: Sendable, Equatable {
        /// 没有任何选中的 managed uninstall 项。
        case empty
        /// Simulator 正在运行，**拒绝**任何 simctl 删除（避免破坏正在运行的实例）。
        case blockedSimulatorRunning(displayNames: [String])
        /// 选中项中存在缺失或非法受管 UUID 的 hit。
        case invalid(reason: String)
        /// 已通过预检，可以执行。
        case ready(items: [Item])
    }

    /// 一条 simctl 删除项的执行结果。
    public struct Outcome: Sendable, Hashable {
        public let item: Item
        /// `true` 表示已通过 allowlist/尾参校验并跨过执行器提交边界。
        /// 启动前拒绝仍会作为失败展示，但不能进入 submission receipt。
        public let wasSubmitted: Bool
        /// 仅当 `exitCode == 0` 视为成功。
        public let exitCode: Int32
        /// 子进程 stdout/stderr 合并输出（截断到 512 字符避免 alert 文案过长）。
        public let truncatedOutput: String

        public var isSuccess: Bool { exitCode == 0 }
    }

    /// Independent receipt for destructive command execution. It deliberately
    /// does not reuse `DeletionSubmissionReceipt`: simctl does not call
    /// `NSWorkspace.recycle` and must never masquerade as a Trash submission.
    public struct SubmissionReceipt: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let submittedItemIDs: [String]
        public let submittedAt: Date

        fileprivate init(id: UUID, submittedItemIDs: [String], submittedAt: Date) {
            self.id = id
            self.submittedItemIDs = submittedItemIDs
            self.submittedAt = submittedAt
        }
    }

    /// v2026.07.15：同一卸载 sheet 使用的逐项事件。事件只包含冻结 item 与终态，
    /// UI 不回读可变 cards/hits，因此慢命令完成后不会把旧页面状态覆盖回来。
    public enum ExecutionEvent: Sendable, Hashable {
        case started(index: Int, total: Int, item: Item)
        case finished(index: Int, total: Int, outcome: Outcome)
    }

    /// 可协作停止令牌。`simctl runtime delete` 正在卸载/卸载磁盘时不可安全强杀；
    /// stop 只在当前项自然结束后阻止提交下一项。
    public actor StopControl {
        private var stopRequested = false

        public init() {}

        public func requestStop() {
            stopRequested = true
        }

        func shouldContinue() -> Bool {
            !stopRequested
        }
    }

    /// 带逐项进度的系统管理卸载终态。只有真正提交过至少一项时才生成 receipt；
    /// 未提交项作为 skipped 保留，不能伪装成失败或成功。
    public struct ManagedExecutionCompletion: Sendable, Equatable {
        public let receipt: SubmissionReceipt?
        public let outcomes: [Outcome]
        public let skippedItems: [Item]

        public var succeededCount: Int { outcomes.count(where: \.isSuccess) }
        public var failedCount: Int { outcomes.count - succeededCount }

        fileprivate init(receipt: SubmissionReceipt?,
                         outcomes: [Outcome],
                         skippedItems: [Item]) {
            self.receipt = receipt
            self.outcomes = outcomes
            self.skippedItems = skippedItems
        }
    }

    /// 注入式 Simulator 运行检测——单测中可注入 `{ false }` / `{ true }` stub。
    public typealias SimulatorRunningProbe = @Sendable () -> Bool

    private let executor: SubprocessExecutor
    private let isSimulatorRunning: SimulatorRunningProbe

    public init(executor: SubprocessExecutor,
                isSimulatorRunning: @escaping SimulatorRunningProbe) {
        // Managed destructive operations may not reuse the query timeout policy. Dry-run is
        // exempt because no Process is launched; every real coordinator must wait for the
        // current CoreSimulator transaction's terminal status.
        precondition(
            executor.dryRun || executor.terminalWaitPolicy == .waitUntilExit,
            "Simulator managed operations must use waitUntilExit"
        )
        self.executor = executor
        self.isSimulatorRunning = isSimulatorRunning
    }

    /// 测试可见的生命周期合同；不暴露 executor 本身，避免绕过类型化 plan 执行任意命令。
    var terminalWaitPolicy: SubprocessExecutor.TerminalWaitPolicy {
        executor.terminalWaitPolicy
    }

    /// 预检——从"卡片 → 命中 → 选中"三层关系折叠为可执行 plan。
    ///
    /// - Parameters:
    ///   - cards: 当前工作流所有卡片。
    ///   - cardHits: 每张卡的命中列表。
    ///   - selected: 用户勾选的 hit.id 集合。
    /// - Returns: 见 [Plan]。
    public func prepare(cards: [DeveloperCard],
                        cardHits: [String: [WorkflowScanHit]],
                        selected: Set<String>) -> Plan {
        var items: [Item] = []
        var invalidNames: [String] = []
        for card in cards {
            // 仅类型化 managedUninstall 进入本流程；filesystem 永远由 TrashPipeline 处理。
            guard case let .managedUninstall(kind) = card.recipe else { continue }
            guard let hits = cardHits[card.id] else { continue }
            let chosen = hits.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            for hit in chosen {
                guard let tail = hit.managedUninstallIdentifier, !tail.isEmpty else {
                    // 扫描器没把 tailArg 填上——拒绝该项，避免拼出残缺命令
                    invalidNames.append(hit.displayName)
                    continue
                }
                guard Self.isValidTailArg(tail, for: kind) else {
                    invalidNames.append(hit.displayName)
                    continue
                }
                items.append(Item(
                    cardID: card.id,
                    hitID: hit.id,
                    displayName: hit.displayName,
                    kind: kind,
                    sizeBytes: hit.sizeBytes,
                    executable: kind.executable,
                    args: kind.argsPrefix + [tail]
                ))
            }
        }

        if !invalidNames.isEmpty {
            return .invalid(reason: invalidNames.joined(separator: "\n"))
        }
        if items.isEmpty {
            return .empty
        }
        if isSimulatorRunning() {
            return .blockedSimulatorRunning(displayNames: items.map { $0.displayName })
        }
        return .ready(items: items)
    }

    /// Revalidate an immutable command plan without consulting workflow cards or hits.
    ///
    /// The UI freezes [Item] values before it presents destructive confirmation. The
    /// Simulator process can still start while either confirmation sheet is open, so
    /// execution must probe that volatile condition again while continuing to consume
    /// only the frozen item list.
    public func revalidate(items: [Item]) -> Plan {
        guard !items.isEmpty else { return .empty }
        if isSimulatorRunning() {
            return .blockedSimulatorRunning(displayNames: items.map(\.displayName))
        }
        return .ready(items: items)
    }

    /// v2026.07.15：提供给 managed uninstall sheet 的可观察执行入口。
    /// 子进程在 detached task 上等待真实终态，逐项事件再异步回到调用方，主线程不会
    /// 被阻塞。停止请求只影响尚未提交项，保持系统管理器的原子操作边界。
    public func executeManaged(
        items: [Item],
        stopControl: StopControl,
        onEvent: @escaping @Sendable (ExecutionEvent) async -> Void
    ) async -> ManagedExecutionCompletion {
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(items.count)
        var skippedItems: [Item] = []

        for (offset, item) in items.enumerated() {
            guard await stopControl.shouldContinue() else {
                skippedItems = Array(items[offset...])
                break
            }
            let index = offset + 1
            await onEvent(.started(index: index, total: items.count, item: item))
            let outcome = await executeOne(item)
            outcomes.append(outcome)
            await onEvent(.finished(index: index, total: items.count, outcome: outcome))
        }

        let submittedIDs = outcomes.filter(\.wasSubmitted).map(\.item.hitID)
        let receipt = submittedIDs.isEmpty ? nil : SubmissionReceipt(
            id: UUID(),
            submittedItemIDs: submittedIDs,
            submittedAt: Date()
        )
        return ManagedExecutionCompletion(
            receipt: receipt,
            outcomes: outcomes,
            skippedItems: skippedItems
        )
    }

    /// stdout/stderr 文案截断——避免 alert 列出几 KB 的输出撑爆 UI。
    private static func truncate(_ raw: String, max: Int = 512) -> String {
        if raw.count <= max { return raw }
        return String(raw.prefix(max)) + "…"
    }

    private func executeOne(_ item: Item) async -> Outcome {
        await Task.detached(priority: .userInitiated) { [executor] in
            do {
                let result = try executor.run(executable: item.executable, args: item.args)
                return Outcome(
                    item: item,
                    // **v2026.07.15 receipt 根因修复**：executor 的负值是内部终态，
                    // -1 launch failed、-2 query timeout 都不能证明命令跨过了 Process
                    // submission boundary。只有系统进程真实返回的非负 exit status 才进 receipt。
                    wasSubmitted: result.exitCode >= 0,
                    exitCode: result.exitCode,
                    truncatedOutput: Self.truncate(result.output)
                )
            } catch {
                GSYLog.warning(.app, "Simulator managed uninstall 抛错: \(error)")
                return Outcome(
                    item: item,
                    wasSubmitted: false,
                    exitCode: -3,
                    truncatedOutput: "throw: \(error)"
                )
            }
        }.value
    }

    private static func isValidTailArg(_ tail: String, for kind: ManagedUninstallRecipe) -> Bool {
        switch kind {
        case .simulatorDevice:
            return isUUID(tail)
        case .simulatorRuntime:
            // Xcode 26 `simctl runtime delete` consumes the runtime image UUID returned by
            // `simctl runtime list -j`; the semantic `com.apple.CoreSimulator...` ID fails.
            return isUUID(tail)
        }
    }

    private static func isUUID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == lengths.count else { return false }
        for (part, length) in zip(parts, lengths) {
            guard part.count == length,
                  part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

    /// 默认 Simulator 运行检测：扫描 NSRunningApplication 是否含 `com.apple.iphonesimulator`。
    /// 与 [AppleWorkflow.defaultSimulatorRunning] 同款语义，仅副本于 AppUI 侧便于无 ScanKit 直接调用。
    public static let defaultSimulatorRunning: SimulatorRunningProbe = AppleWorkflow.defaultSimulatorRunning
}
