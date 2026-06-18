import Foundation
import ScanKit
import LogKit

/// v1.7 M1 PR-9：simctl 真删协调器（独立于 SwiftUI，便于单测）。
///
/// 设计动机：
/// - PR-5 落地的 [WorkflowDetailViewModel.performDelete] 把 `.commandLine` recipe 卡的勾选项
///   仅作 alert 提示，并未真正执行 `xcrun simctl delete / runtime delete`。
/// - PR-9 接通真删，但 simctl 是**破坏性**命令（删除 booted 模拟器会丢未保存的 app 数据 + Xcode 自动重连失败），
///   必须有一套独立、可测、可回滚的协调层；如果直接堆进 ViewModel 会让 alert/sheet 状态机和真删逻辑深度耦合，
///   也无法在不起 SwiftUI 上下文的情况下单测 allowlist / Simulator-running guard / 部分失败汇总。
///
/// 三段式执行：
/// 1. **prepare**：对选中 hits 做预检——Simulator 运行中 → 直接 `.blockedSimulatorRunning`；
///    无 commandLineTailArg → `.invalid`；其他 → `.ready(plan)`。
/// 2. **confirm**：UI 侧两轮确认（first sheet → second sheet "我确认"），不在本协调器里维护——
///    它只提供 `Plan` 对象与"提交执行"入口。
/// 3. **execute**：对 plan 中每条 item 逐个调 SubprocessExecutor。任何一条失败仅记入汇总，**不中断**剩余项；
///    全部跑完后返回 [Outcome]。
///
/// 与 [SubprocessExecutor] 的契约：
/// - 协调器拼出的 args 一定形如 `argsPrefix + [tailArg]`（如 `["simctl", "delete", <UDID>]`），
///   执行器内层 allowlist 校验做最后兜底——任何 tailArg 都不能突破 allowlist 既定的命令前缀。
/// - timeout 由调用方注入的 SubprocessExecutor 决定；本协调器不替业务方决策 timeout。
///
/// 与 ViewModel 的边界：
/// - 协调器**不持有** @Published / SwiftUI 状态——只暴露纯函数 + struct 结果；
/// - ViewModel 拿到 [Outcome] 后自己拼 alert 文案 / 触发 refreshAll。
public struct SimulatorDeleteCoordinator: Sendable {

    /// 一条待执行的 simctl 删除项。
    public struct Item: Sendable, Hashable {
        /// 关联卡的稳定 ID，用于失败时回写哪张卡的 hits 还需保留。
        public let cardID: String
        /// hit 自身 ID（= url.path），ViewModel 用来从 selected set 中移除已成功项。
        public let hitID: String
        /// 用户可读名（如 "iPhone 16 · UDID..."），用于 sheet 列表与失败 alert。
        public let displayName: String
        /// 完整可执行路径（如 `/usr/bin/xcrun`）。
        public let executable: String
        /// 完整 args（已 append tailArg），如 `["simctl", "delete", "<UDID>"]`。
        public let args: [String]
    }

    /// `prepare` 的产物。
    public enum Plan: Sendable, Equatable {
        /// 没有任何选中的 commandLine 项——UI 侧应跳过 simctl 流程。
        case empty
        /// Simulator 正在运行，**拒绝**任何 simctl 删除（避免破坏正在运行的实例）。
        case blockedSimulatorRunning(displayNames: [String])
        /// 选中项中存在缺失 commandLineTailArg 的 hit（不应发生，扫描器逻辑出错才会触发）。
        case invalid(reason: String)
        /// 已通过预检，可以执行。
        case ready(items: [Item])
    }

    /// 一条 simctl 删除项的执行结果。
    public struct Outcome: Sendable, Hashable {
        public let item: Item
        /// 仅当 `exitCode == 0` 视为成功。
        public let exitCode: Int32
        /// 子进程 stdout/stderr 合并输出（截断到 512 字符避免 alert 文案过长）。
        public let truncatedOutput: String

        public var isSuccess: Bool { exitCode == 0 }
    }

    /// 注入式 Simulator 运行检测——单测中可注入 `{ false }` / `{ true }` stub。
    public typealias SimulatorRunningProbe = @Sendable () -> Bool

    private let executor: SubprocessExecutor
    private let isSimulatorRunning: SimulatorRunningProbe

    public init(executor: SubprocessExecutor,
                isSimulatorRunning: @escaping SimulatorRunningProbe) {
        self.executor = executor
        self.isSimulatorRunning = isSimulatorRunning
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
            // 仅 .commandLine recipe 进入本流程；.filesystem 由 ViewModel 走 pipeline.moveToTrash
            guard case let .commandLine(executable, argsPrefix) = card.recipe else { continue }
            guard let hits = cardHits[card.id] else { continue }
            let chosen = hits.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            for hit in chosen {
                guard let tail = hit.commandLineTailArg, !tail.isEmpty else {
                    // 扫描器没把 tailArg 填上——拒绝该项，避免拼出残缺命令
                    invalidNames.append(hit.displayName)
                    continue
                }
                guard Self.isValidTailArg(tail, for: argsPrefix) else {
                    invalidNames.append(hit.displayName)
                    continue
                }
                items.append(Item(
                    cardID: card.id,
                    hitID: hit.id,
                    displayName: hit.displayName,
                    executable: executable,
                    args: argsPrefix + [tail]
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

    /// 执行——对 plan 中每条 item 串行调 SubprocessExecutor。
    ///
    /// 串行而非并发的理由：simctl 自身对并发 delete 的健壮性未知，
    /// 串行可以保证"失败一条不污染下一条"的强次序，且 timeout 累加可被 UI 进度文案预测。
    public func execute(items: [Item]) async -> [Outcome] {
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(items.count)
        for item in items {
            let outcome: Outcome
            do {
                let result = try executor.run(executable: item.executable, args: item.args)
                outcome = Outcome(item: item,
                                  exitCode: result.exitCode,
                                  truncatedOutput: Self.truncate(result.output))
            } catch {
                GSYLog.warning(.app, "SimulatorDeleteCoordinator run 抛错: \(error)")
                outcome = Outcome(item: item,
                                  exitCode: -3,
                                  truncatedOutput: "throw: \(error)")
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// stdout/stderr 文案截断——避免 alert 列出几 KB 的输出撑爆 UI。
    private static func truncate(_ raw: String, max: Int = 512) -> String {
        if raw.count <= max { return raw }
        return String(raw.prefix(max)) + "…"
    }

    private static func isValidTailArg(_ tail: String, for argsPrefix: [String]) -> Bool {
        if argsPrefix == ["simctl", "delete"] {
            return isUUID(tail)
        }
        if argsPrefix == ["simctl", "runtime", "delete"] {
            return tail.hasPrefix("com.apple.CoreSimulator.SimRuntime.")
                && tail.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        }
        return false
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
