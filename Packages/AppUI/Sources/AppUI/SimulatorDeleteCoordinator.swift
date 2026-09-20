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
/// - 生产调用方必须注入 `.waitUntilExit`；查询 timeout 不适用于正在提交的系统卸载；
/// - v2026.07.16 起，观察窗口耗尽只产生 `.unknownAfterStall`，不会终止 CoreSimulator。
///
/// 与 ViewModel 的边界：
/// - 协调器**不持有** @Published / SwiftUI 状态——只暴露纯函数 + struct 结果；
/// - ViewModel 消费逐项事件并只移除成功 rows，不触发无关卡片全量重扫。
public struct SimulatorDeleteCoordinator: Sendable {

    /// UI 等待单个 CoreSimulator 事务真实终态的默认观察窗口。它不是进程 timeout；
    /// 达到阈值后只把状态标记为 unknown，系统命令仍在后台自然完成。
    public static let defaultManagedObservationLimit: TimeInterval = 30

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
        /// “命令提交”与“系统确认终态”必须分开。unknown 不能伪装成失败，更不能按成功
        /// 从页面移除；上层只能稍后重新扫描 CoreSimulator 权威清单对账。
        public enum Status: Sendable, Hashable {
            case notSubmitted(exitCode: Int32)
            case confirmedTerminal(exitCode: Int32)
            case unknownAfterStall
        }

        /// 用户错误只暴露类型，不携带 simctl stdout/stderr。UI 必须用 String Catalog
        /// 将该类型映射为当前语言；原始输出只进入结构化日志/技术诊断。
        public enum FailureReason: Sendable, Hashable {
            case commandRejected
            case processLaunchFailed
            case commandFailed(exitCode: Int32)
            case simulatorOrDeviceActive
            case safetyVerificationUnavailable
            case duplicatePendingOperation
            case persistentPendingOperation
            case resourceAlreadyAbsent
            case observationEndedWithoutTerminal
        }

        public let item: Item
        public let status: Status
        public let failureReason: FailureReason?
        /// 兼容既有 UI 投影的安全字段。v2026.07.16 起这里永远不包含 raw simctl 输出；
        /// UI 应优先按 failureReason / status 本地化。
        public let truncatedOutput: String

        public init(item: Item,
                    status: Status,
                    truncatedOutput: String = "",
                    failureReason: FailureReason? = nil) {
            self.item = item
            self.status = status
            self.failureReason = failureReason
            self.truncatedOutput = truncatedOutput
        }

        public var wasSubmitted: Bool {
            switch status {
            case .notSubmitted: false
            case .confirmedTerminal, .unknownAfterStall: true
            }
        }

        /// 兼容既有结果展示；unknown 的 -4 仅为内部 sentinel，上层应优先读 `status`。
        public var exitCode: Int32 {
            switch status {
            case .notSubmitted(let exitCode), .confirmedTerminal(let exitCode): exitCode
            case .unknownAfterStall: -4
            }
        }

        public var isSuccess: Bool {
            if case .confirmedTerminal(exitCode: 0) = status { return true }
            return false
        }

        public var isUnknown: Bool {
            if case .unknownAfterStall = status { return true }
            return false
        }
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
        case submitted(index: Int, total: Int, item: Item)
        case running(index: Int, total: Int, item: Item)
        case stalled(index: Int, total: Int, item: Item, elapsed: TimeInterval)
        case blockedSimulatorRunning(index: Int, total: Int, item: Item)
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

    /// 会话级 managed-operation 注册表。
    ///
    /// **v2026.07.16 根因修复**：观察窗口结束不代表 `simctl` 结束。旧实现返回 unknown
    /// 后丢掉 AsyncStream 消费者，同一 UUID 可以再次提交。注册表持有唯一 monitor task，
    /// 终态到达前原子拒绝同 UUID；迟到终态同时记入 reconciliation 队列。
    private actor PendingManagedOperationRegistry {
        private struct Entry {
            let token: UUID
            var monitorTask: Task<Void, Never>?
            var terminalOutcome: Outcome?
            var waiters: [UUID: CheckedContinuation<Outcome?, Never>] = [:]
        }

        private var entries: [String: Entry] = [:]

        func reserve(identifier: String) -> UUID? {
            guard entries[identifier] == nil else { return nil }
            let token = UUID()
            entries[identifier] = Entry(
                token: token,
                monitorTask: nil,
                terminalOutcome: nil
            )
            return token
        }

        func attach(_ task: Task<Void, Never>, identifier: String, token: UUID) {
            guard var entry = entries[identifier], entry.token == token else { return }
            entry.monitorTask = task
            entries[identifier] = entry
        }

        func release(identifier: String, token: UUID) {
            guard entries[identifier]?.token == token else { return }
            entries.removeValue(forKey: identifier)
        }

        func finishLate(identifier: String, token: UUID, outcome: Outcome) {
            guard var entry = entries[identifier], entry.token == token else { return }
            if entry.waiters.isEmpty {
                // 终态 tombstone 保留到调用方消费；这段窗口内同 UUID 仍不可重提。
                entry.terminalOutcome = outcome
                entries[identifier] = entry
                return
            }
            entries.removeValue(forKey: identifier)
            for waiter in entry.waiters.values {
                waiter.resume(returning: outcome)
            }
        }

        func awaitReconciled(identifier: String) async -> Outcome? {
            guard var entry = entries[identifier] else { return nil }
            if let terminal = entry.terminalOutcome {
                entries.removeValue(forKey: identifier)
                return terminal
            }
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                if Task.isCancelled { return nil }
                return await withCheckedContinuation { continuation in
                    entry.waiters[waiterID] = continuation
                    entries[identifier] = entry
                }
            } onCancel: {
                Task { await self.cancelWaiter(identifier: identifier, waiterID: waiterID) }
            }
        }

        private func cancelWaiter(identifier: String, waiterID: UUID) {
            guard var entry = entries[identifier],
                  let waiter = entry.waiters.removeValue(forKey: waiterID) else { return }
            entries[identifier] = entry
            waiter.resume(returning: nil)
        }

        func pendingCount() -> Int { entries.count }

        func takeReconciled() -> [Outcome] {
            let terminalEntries = entries.filter { $0.value.terminalOutcome != nil }
            for key in terminalEntries.keys { entries.removeValue(forKey: key) }
            return terminalEntries.values.compactMap(\.terminalOutcome)
        }
    }

    /// Process 会话共享，而非 ViewModel/Coordinator 实例私有。这样用户关闭工作流页面、
    /// 重新进入并构造新 coordinator 时，旧 detached `simctl` 未终态前仍会被同 UUID
    /// 原子挡住。v2026.07.16：本 actor 只负责进程内等待者/终态分发；跨重启与跨进程
    /// 去重由紧邻的 persistent ledger 提供，两者不能互相替代。
    private static let processPendingRegistry = PendingManagedOperationRegistry()
    private static let persistentManagedOperationLedger = PersistentSimulatorManagedOperationLedger()

    /// One executeOne call crosses three synchronous/asynchronous boundaries: safety guard,
    /// persistence barrier and terminal stream consumption. The immutable ledger attempt token
    /// must be handed across all three without a captured mutable var under Swift 6 concurrency.
    /// NSLock protects that one-time handoff; replacement attempts can never reuse the token.
    private final class ManagedLedgerAttemptSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var storedAttemptID: UUID?

        func install(_ attemptID: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard storedAttemptID == nil else { return false }
            storedAttemptID = attemptID
            return true
        }

        func value() -> UUID? {
            lock.lock()
            defer { lock.unlock() }
            return storedAttemptID
        }
    }

    private actor FirstOutcomeGate {
        private var value: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        /// - Returns: true 仅当本次是第一个可交还调用方的状态。
        func resolve(_ outcome: Outcome) -> Bool {
            guard value == nil else { return false }
            value = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
            return true
        }

        func wait() async -> Outcome {
            if let value { return value }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    /// 带逐项进度的系统管理卸载终态。只有真正提交过至少一项时才生成 receipt；
    /// 未提交项作为 skipped 保留，不能伪装成失败或成功。
    public struct ManagedExecutionCompletion: Sendable, Equatable {
        public enum InterruptionReason: Sendable, Equatable {
            case stopRequested
            case simulatorStarted
            case currentItemStatusUnknown
        }

        public let receipt: SubmissionReceipt?
        public let outcomes: [Outcome]
        public let skippedItems: [Item]
        public let interruptionReason: InterruptionReason?

        public var succeededCount: Int { outcomes.count(where: \.isSuccess) }
        public var unknownCount: Int { outcomes.count(where: \.isUnknown) }
        public var failedCount: Int { outcomes.count - succeededCount - unknownCount }

        fileprivate init(receipt: SubmissionReceipt?,
                         outcomes: [Outcome],
                         skippedItems: [Item],
                         interruptionReason: InterruptionReason?) {
            self.receipt = receipt
            self.outcomes = outcomes
            self.skippedItems = skippedItems
            self.interruptionReason = interruptionReason
        }

        /// 将 stalled 后到达的权威终态替换回原 item；不改变未提交项和 receipt 边界。
        /// 同一 hit 只保留最新终态，供 ViewModel 在 late `.finished` 时更新 sheet。
        public func reconciling(_ lateOutcome: Outcome) -> ManagedExecutionCompletion {
            var reconciledOutcomes = outcomes
            if let index = reconciledOutcomes.firstIndex(where: {
                $0.item.hitID == lateOutcome.item.hitID
            }) {
                reconciledOutcomes[index] = lateOutcome
            } else {
                reconciledOutcomes.append(lateOutcome)
            }
            return ManagedExecutionCompletion(
                receipt: receipt,
                outcomes: reconciledOutcomes,
                skippedItems: skippedItems,
                interruptionReason: interruptionReason
            )
        }
    }

    /// 注入式 Simulator 运行检测——单测中可注入 `{ false }` / `{ true }` stub。
    public typealias SimulatorRunningProbe = @Sendable () -> Bool
    public typealias BootedDeviceProbe = @Sendable () -> SimctlBootedDeviceProbe.ProbeResult
    public typealias ManagedResourceAuthorityProbe = @Sendable (
        _ identifier: String,
        _ kind: ManagedUninstallRecipe
    ) -> SimctlManagedResourceAuthorityProbe.Presence

    private let executor: SubprocessExecutor
    private let isSimulatorRunning: SimulatorRunningProbe
    private let bootedDeviceProbe: BootedDeviceProbe
    private let managedResourceAuthorityProbe: ManagedResourceAuthorityProbe
    private let managedOperationLedger: any SimulatorManagedOperationLedger
    private let managedObservationLimit: TimeInterval
    private let pendingRegistry: PendingManagedOperationRegistry

    public init(executor: SubprocessExecutor,
                isSimulatorRunning: @escaping SimulatorRunningProbe,
                bootedDeviceProbe: @escaping BootedDeviceProbe = Self.defaultBootedDeviceProbe,
                managedResourceAuthorityProbe: @escaping ManagedResourceAuthorityProbe = Self.defaultManagedResourceAuthorityProbe,
                managedOperationLedger: (any SimulatorManagedOperationLedger)? = nil,
                managedObservationLimit: TimeInterval = Self.defaultManagedObservationLimit) {
        // Managed destructive operations may not reuse the query timeout policy. Dry-run is
        // exempt because no Process is launched; every real coordinator must wait for the
        // current CoreSimulator transaction's terminal status.
        precondition(
            executor.dryRun || executor.terminalWaitPolicy == .waitUntilExit,
            "Simulator managed operations must use waitUntilExit"
        )
        precondition(
            managedObservationLimit.isFinite && managedObservationLimit > 0,
            "Managed observation limit must be finite and positive"
        )
        self.executor = executor
        self.isSimulatorRunning = isSimulatorRunning
        self.bootedDeviceProbe = bootedDeviceProbe
        self.managedResourceAuthorityProbe = managedResourceAuthorityProbe
        self.managedOperationLedger = managedOperationLedger
            ?? (executor.dryRun
                ? InMemorySimulatorManagedOperationLedger()
                : Self.persistentManagedOperationLedger)
        self.managedObservationLimit = managedObservationLimit
        self.pendingRegistry = Self.processPendingRegistry
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
        var seenManagedIdentifiers = Set<String>()
        var seenHitIDs = Set<String>()
        for card in cards {
            // 仅类型化 managedUninstall 进入本流程；filesystem 永远由 TrashPipeline 处理。
            guard case let .managedUninstall(kind) = card.recipe else { continue }
            guard let hits = cardHits[card.id] else { continue }
            let chosen = hits.filter { selected.contains($0.id) }
            guard !chosen.isEmpty else { continue }
            for hit in chosen {
                guard Self.isUnambiguousAbsoluteResourceURL(hit.url),
                      seenHitIDs.insert(hit.id).inserted else {
                    invalidNames.append(hit.displayName)
                    continue
                }
                guard let tail = hit.managedUninstallIdentifier, !tail.isEmpty else {
                    // 扫描器没把 tailArg 填上——拒绝该项，避免拼出残缺命令
                    invalidNames.append(hit.displayName)
                    continue
                }
                guard Self.isValidTailArg(tail, for: kind) else {
                    invalidNames.append(hit.displayName)
                    continue
                }
                guard seenManagedIdentifiers.insert(Self.canonicalManagedIdentifier(tail)).inserted else {
                    // 两个 row 指向同一个 managed UUID 时，选择/进度/receipt 都无法保持
                    // 一一对应；整批拒绝而不是“去重后偷偷执行一次”。
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
        var seenIdentifiers = Set<String>()
        var seenHitIDs = Set<String>()
        for item in items {
            guard let identifier = Self.managedIdentifier(for: item),
                  Self.isValidTailArg(identifier, for: item.kind),
                  Self.isUnambiguousAbsolutePath(item.hitID),
                  seenIdentifiers.insert(Self.canonicalManagedIdentifier(identifier)).inserted,
                  seenHitIDs.insert(item.hitID).inserted else {
                return .invalid(reason: item.displayName)
            }
        }
        if isSimulatorRunning() {
            return .blockedSimulatorRunning(displayNames: items.map(\.displayName))
        }
        return .ready(items: items)
    }

    /// v2026.07.15：提供给 managed uninstall sheet 的可观察执行入口。
    /// 子进程在 detached task 上等待真实终态，逐项事件再异步回到调用方，主线程不会
    /// 被阻塞。停止请求只影响尚未提交项，保持系统管理器的原子操作边界。
    ///
    /// **v2026.07.16 根因修复**：`reviewIdentity` 必须来自冻结 Workflow intent 的扫描
    /// session/revision，并贯穿本批次所有 item。不得在点击执行时生成随机 token；否则
    /// 同一次陈旧复核可在 App 重启后清除自己的 stale reservation 并重复提交。
    public func executeManaged(
        items: [Item],
        reviewIdentity: SimulatorManagedReviewIdentity,
        stopControl: StopControl,
        onEvent: @escaping @Sendable (ExecutionEvent) async -> Void
    ) async -> ManagedExecutionCompletion {
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(items.count)
        var skippedItems: [Item] = []
        var interruptionReason: ManagedExecutionCompletion.InterruptionReason?

        for (offset, item) in items.enumerated() {
            guard await stopControl.shouldContinue() else {
                skippedItems = Array(items[offset...])
                interruptionReason = .stopRequested
                break
            }
            let index = offset + 1
            await onEvent(.started(index: index, total: items.count, item: item))

            let outcome = await executeOne(
                item,
                reviewIdentity: reviewIdentity,
                index: index,
                total: items.count,
                onEvent: onEvent
            )
            outcomes.append(outcome)
            await onEvent(.finished(index: index, total: items.count, outcome: outcome))

            if outcome.failureReason == .simulatorOrDeviceActive {
                if index < items.count { skippedItems = Array(items[index...]) }
                interruptionReason = .simulatorStarted
                break
            }
            if outcome.failureReason == .safetyVerificationUnavailable
                || outcome.failureReason == .duplicatePendingOperation
                || outcome.failureReason == .persistentPendingOperation
                || outcome.failureReason == .resourceAlreadyAbsent {
                if index < items.count { skippedItems = Array(items[index...]) }
                // 无法证明安全或同 UUID 仍有 pending transaction 时，因果状态均未知；
                // 复用既有“停止并稍后权威对账”终态，不继续提交其它项。
                interruptionReason = .currentItemStatusUnknown
                break
            }
            if outcome.isUnknown {
                // 当前 CoreSimulator 事务仍可能在后台运行；在它没有终态时继续提交下一项
                // 会让后续对账失去因果边界，因此整批安全停止，剩余项保持未提交。
                if index < items.count {
                    skippedItems = Array(items[index...])
                }
                interruptionReason = .currentItemStatusUnknown
                break
            }
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
            skippedItems: skippedItems,
            interruptionReason: interruptionReason
        )
    }

    /// raw stdout/stderr 只进入日志技术详情，不得传到用户 sheet。
    private static func logExcerpt(_ raw: String, max: Int = 512) -> String {
        if raw.count <= max { return raw }
        return String(raw.prefix(max)) + "…"
    }

    private func executeOne(
        _ item: Item,
        reviewIdentity: SimulatorManagedReviewIdentity,
        index: Int,
        total: Int,
        onEvent: @escaping @Sendable (ExecutionEvent) async -> Void
    ) async -> Outcome {
        let registryIdentifier = Self.registryIdentifier(for: item)
        guard let reservationToken = await pendingRegistry.reserve(identifier: registryIdentifier) else {
            return Outcome(
                item: item,
                status: .notSubmitted(exitCode: -4),
                failureReason: .duplicatePendingOperation
            )
        }

        let updates: AsyncStream<SubprocessExecutor.ManagedExecutionUpdate>
        let managedIdentifier = Self.managedIdentifier(for: item)
        let ledgerAttemptSlot = ManagedLedgerAttemptSlot()
        do {
            updates = try executor.observeManagedExecution(
                executable: item.executable,
                args: item.args,
                stallAfter: managedObservationLimit,
                preSubmissionGuard: {
                    [isSimulatorRunning,
                     bootedDeviceProbe,
                     managedResourceAuthorityProbe,
                     managedOperationLedger,
                     reviewIdentity] in
                    // 这两个探针在 SubprocessExecutor 内紧邻 Process.run() 同步执行。
                    // App 进程检查覆盖 GUI；simctl 权威清单覆盖 headless Booted devices。
                    if let managedIdentifier {
                        let observation = managedOperationLedger.observation(
                            identifier: managedIdentifier,
                            kind: item.kind
                        )
                        switch observation.state {
                        case .reservedByActiveProcess:
                            // 另一个活跃 App 实例仍处于 reserve → submission 屏障之间；
                            // 绝不能把它误当成重启遗留记录清除。
                            return .persistentPendingOperation
                        case .staleReservation:
                            // **v2026.07.16 根因修复**：只有 PID + 启动时间证明原 owner
                            // 已死亡的 reserved 才能清除。本 executeOne 来自一次新的用户复核，
                            // 因而可以继续完成本轮紧邻提交重验。
                            guard let observedAttemptID = observation.attemptID,
                                  managedOperationLedger.clearStaleReservationForFreshReview(
                                identifier: managedIdentifier,
                                kind: item.kind,
                                expectedAttemptID: observedAttemptID,
                                candidateReviewIdentity: reviewIdentity
                            ) else { return .verificationUnavailable }
                        case .submitted:
                            switch managedResourceAuthorityProbe(managedIdentifier, item.kind) {
                            case .present:
                                return .persistentPendingOperation
                            case .absent:
                                guard let observedAttemptID = observation.attemptID,
                                      managedOperationLedger.clearAfterAuthoritativeAbsence(
                                    identifier: managedIdentifier,
                                    kind: item.kind,
                                    expectedAttemptID: observedAttemptID
                                ) else { return .verificationUnavailable }
                                // 当前 frozen row 已陈旧；清除 tombstone 后也不对不存在资源
                                // 再发 delete，要求 UI 重扫权威清单。
                                return .resourceAlreadyAbsent
                            case .verificationUnavailable:
                                return .verificationUnavailable
                            }
                        case .terminal(let exitCode):
                            if exitCode != 0 {
                                // 真实 terminationStatus 证明旧进程已结束；清除后仅允许当前
                                // 新复核发起重试，不能让普通命令失败永久锁死该资源。
                                guard let observedAttemptID = observation.attemptID,
                                      managedOperationLedger.clearAfterConfirmedTerminalFailure(
                                    identifier: managedIdentifier,
                                    kind: item.kind,
                                    expectedAttemptID: observedAttemptID
                                ) else { return .verificationUnavailable }
                            } else {
                                // exit 0 但权威清单仍 present 可能是 CoreSimulator 尚未完成
                                // 可见性收敛；继续 fail closed，直到 authority 明确 absent。
                                switch managedResourceAuthorityProbe(managedIdentifier, item.kind) {
                                case .present:
                                    return .persistentPendingOperation
                                case .absent:
                                    guard let observedAttemptID = observation.attemptID,
                                          managedOperationLedger.clearAfterAuthoritativeAbsence(
                                        identifier: managedIdentifier,
                                        kind: item.kind,
                                        expectedAttemptID: observedAttemptID
                                    ) else { return .verificationUnavailable }
                                    return .resourceAlreadyAbsent
                                case .verificationUnavailable:
                                    return .verificationUnavailable
                                }
                            }
                        case .unavailable:
                            return .verificationUnavailable
                        case .absent:
                            break
                        }
                    }
                    // **v2026.07.16 P1 TOCTOU 修复**：`simctl list devices --json` 最长可
                    // 阻塞数秒，如果先查 GUI 进程，Simulator.app 可在查询窗口内启动。
                    // 因此先完成 headless device 权威查询，再做最后一次 GUI 进程
                    // 检查；随后立即 reserve intent，并由 SubprocessExecutor 无 suspension
                    // 地紧接 `Process.run()`。这将 GUI 竞态窗口收窄到最小。
                    switch bootedDeviceProbe() {
                    case .safeToSubmit:
                        guard !isSimulatorRunning() else { return .blocked }
                        if let managedIdentifier {
                            switch managedOperationLedger.reserve(
                                identifier: managedIdentifier,
                                kind: item.kind,
                                reviewIdentity: reviewIdentity
                            ) {
                            case .reserved(let attemptID):
                                // **v2026.07.16 ABA root-cause fix**: the exact reservation
                                // generation must survive the authority-probe → run → terminal
                                // chain. A late callback from an older generation may never clear
                                // or advance this replacement attempt.
                                guard ledgerAttemptSlot.install(attemptID) else {
                                    _ = managedOperationLedger.clearAfterProvenNoLaunch(
                                        identifier: managedIdentifier,
                                        kind: item.kind,
                                        expectedAttemptID: attemptID
                                    )
                                    return .verificationUnavailable
                                }
                                return .allow
                            case .alreadyPending:
                                return .persistentPendingOperation
                            case .persistenceFailed:
                                return .verificationUnavailable
                            }
                        }
                        // 非 production UUID 命令仅存在于注入式 executor 测试。
                        return .allow
                    case .activeDevices:
                        return .blocked
                    case .verificationUnavailable:
                        return .verificationUnavailable
                    }
                },
                preLaunchPersistenceBarrier: {
                    [managedOperationLedger, ledgerAttemptSlot] in
                    guard let managedIdentifier else { return true }
                    guard let attemptID = ledgerAttemptSlot.value() else { return false }
                    let didPersistSubmission = managedOperationLedger.markSubmitted(
                        identifier: managedIdentifier,
                        kind: item.kind,
                        expectedAttemptID: attemptID
                    )
                    if !didPersistSubmission {
                        // 屏障返回 false 后 executor 保证绝不调用 Process.run；清除仅限本
                        // 进程 owner 的 reserved/submitted，失败则保留记录继续 fail closed。
                        _ = managedOperationLedger.clearAfterProvenNoLaunch(
                            identifier: managedIdentifier,
                            kind: item.kind,
                            expectedAttemptID: attemptID
                        )
                    }
                    return didPersistSubmission
                }
            )
        } catch {
            await pendingRegistry.release(
                identifier: registryIdentifier,
                token: reservationToken
            )
            GSYLog.warning(.app, "Simulator managed uninstall rejected before submit: \(error)")
            return Outcome(
                item: item,
                status: .notSubmitted(exitCode: -3),
                failureReason: .commandRejected
            )
        }

        let gate = FirstOutcomeGate()
        let monitor = Task.detached(priority: .userInitiated) {
            [pendingRegistry, ledgerAttemptSlot] in
            var submitted = false
            for await update in updates {
                switch update {
                case .submissionRejected(let decision):
                    let reason: Outcome.FailureReason
                    switch decision {
                    case .allow:
                        // 执行器不应发布 allow；按合同破坏 fail closed。
                        reason = .safetyVerificationUnavailable
                    case .blocked:
                        reason = .simulatorOrDeviceActive
                        await onEvent(.blockedSimulatorRunning(
                            index: index,
                            total: total,
                            item: item
                        ))
                    case .verificationUnavailable:
                        reason = .safetyVerificationUnavailable
                    case .persistentPendingOperation:
                        reason = .persistentPendingOperation
                    case .resourceAlreadyAbsent:
                        reason = .resourceAlreadyAbsent
                    }
                    let outcome = Outcome(
                        item: item,
                        status: .notSubmitted(exitCode: -4),
                        failureReason: reason
                    )
                    _ = await gate.resolve(outcome)
                    await pendingRegistry.release(
                        identifier: registryIdentifier,
                        token: reservationToken
                    )
                    return
                case .submitted:
                    submitted = true
                    await onEvent(.submitted(index: index, total: total, item: item))
                case .running:
                    await onEvent(.running(index: index, total: total, item: item))
                case .stalled(_, let elapsed):
                    await onEvent(.stalled(
                        index: index,
                        total: total,
                        item: item,
                        elapsed: elapsed
                    ))
                    // 调用方在此收到 unknown，但本 monitor 是 AsyncStream 的唯一消费者，
                    // 会继续活到真实终态并由 registry 对账；绝不留下无人消费的 producer。
                    _ = await gate.resolve(Outcome(
                        item: item,
                        status: .unknownAfterStall,
                        failureReason: nil
                    ))
                case .confirmedTerminal(let result):
                    let status: Outcome.Status = submitted
                        ? .confirmedTerminal(exitCode: result.exitCode)
                        : .notSubmitted(exitCode: result.exitCode)
                    let reason = Self.failureReason(for: result)
                    if !result.output.isEmpty {
                        GSYLog.info(
                            .app,
                            "Simulator managed uninstall terminal exit=\(result.exitCode) output=\(Self.logExcerpt(result.output))"
                        )
                    }
                    if !submitted, result.exitCode == -1, let managedIdentifier {
                        // submitted 阶段已在 Process.run 前持久化，但 launch 抛错证明没有
                        // PID/系统事务；这是唯一可安全回滚该阶段的执行器证据。
                        if let attemptID = ledgerAttemptSlot.value() {
                            _ = managedOperationLedger.clearAfterProvenNoLaunch(
                                identifier: managedIdentifier,
                                kind: item.kind,
                                expectedAttemptID: attemptID
                            )
                        }
                    } else if submitted,
                              let managedIdentifier,
                              let attemptID = ledgerAttemptSlot.value() {
                        // **v2026.07.16 根因修复**：先持久记录 confirmed terminal，再决定
                        // 是否清理。若写失败，原 submitted 保持 fail closed；若非零终态
                        // 写入成功，进程已确定退出，可清除并允许下一次用户复核重试。
                        let didRecordTerminal = managedOperationLedger.recordConfirmedTerminal(
                            identifier: managedIdentifier,
                            kind: item.kind,
                            expectedAttemptID: attemptID,
                            exitCode: result.exitCode
                        )
                        if !didRecordTerminal {
                            GSYLog.warning(
                                .app,
                                "Simulator ledger terminal transition failed; keeping submission fail-closed"
                            )
                        } else if result.exitCode != 0 {
                            _ = managedOperationLedger.clearAfterConfirmedTerminalFailure(
                                identifier: managedIdentifier,
                                kind: item.kind,
                                expectedAttemptID: attemptID
                            )
                        } else if managedResourceAuthorityProbe(
                            managedIdentifier,
                            item.kind
                        ) == .absent {
                            _ = managedOperationLedger.clearAfterAuthoritativeAbsence(
                                identifier: managedIdentifier,
                                kind: item.kind,
                                expectedAttemptID: attemptID
                            )
                        }
                    }
                    let outcome = Outcome(
                        item: item,
                        status: status,
                        failureReason: reason
                    )
                    let wasFirstResolution = await gate.resolve(outcome)
                    if wasFirstResolution {
                        await pendingRegistry.release(
                            identifier: registryIdentifier,
                            token: reservationToken
                        )
                    } else {
                        // 不直接发 late event：它可能抢在 executeManaged 的 unknown completion
                        // 落 UI 前到达并随后被旧 completion 覆盖。registry 保存终态 tombstone，
                        // ViewModel 先落 `.finished`，再 await/consume，建立确定性顺序屏障。
                        await pendingRegistry.finishLate(
                            identifier: registryIdentifier,
                            token: reservationToken,
                            outcome: outcome
                        )
                    }
                    return
                }
            }

            // 流异常结束时不能猜成功/失败。若已经提交，只能进入 unknown 并等待重扫；
            // 已提交时 registry 故意保留 pending，防止同 UUID 在无终态证据时重提。
            let outcome = Outcome(
                item: item,
                status: submitted ? .unknownAfterStall : .notSubmitted(exitCode: -3),
                failureReason: .observationEndedWithoutTerminal
            )
            _ = await gate.resolve(outcome)
            if !submitted {
                await pendingRegistry.release(
                    identifier: registryIdentifier,
                    token: reservationToken
                )
            }
        }

        await pendingRegistry.attach(
            monitor,
            identifier: registryIdentifier,
            token: reservationToken
        )
        return await gate.wait()
    }

    private static func failureReason(
        for result: SubprocessExecutor.Result
    ) -> Outcome.FailureReason? {
        switch result.exitCode {
        case 0: nil
        case -1: .processLaunchFailed
        case -3: .commandRejected
        default: .commandFailed(exitCode: result.exitCode)
        }
    }

    /// ViewModel 可在重新打开/重扫时获取已经从 unknown 收敛的终态；正常路径也会收到
    /// 一条迟到 `.finished` 事件。drain 是有意的，避免同一 reconciliation 重放多次。
    public func takeReconciledOutcomes() async -> [Outcome] {
        await pendingRegistry.takeReconciled()
    }

    /// 等待某个 unknown/duplicate-pending 项的迟到终态。调用方应先把 initial completion
    /// 落到 UI，再 await 本方法；因此 returned outcome 不会被旧 unknown 覆盖。
    public func awaitReconciledOutcome(for item: Item) async -> Outcome? {
        await pendingRegistry.awaitReconciled(
            identifier: Self.registryIdentifier(for: item)
        )
    }

    /// 诊断/测试入口：pending > 0 表示至少一个系统事务尚无可信终态，当前会话必须禁重。
    public func pendingManagedOperationCount() async -> Int {
        await pendingRegistry.pendingCount()
    }

    private static func managedIdentifier(for item: Item) -> String? {
        guard item.args.count == item.kind.argsPrefix.count + 1,
              Array(item.args.prefix(item.kind.argsPrefix.count)) == item.kind.argsPrefix else {
            return nil
        }
        return item.args.last
    }

    private static func registryIdentifier(for item: Item) -> String {
        if let identifier = managedIdentifier(for: item), isUUID(identifier) {
            return canonicalManagedIdentifier(identifier)
        }
        // 仅供注入式 executor 测试/诊断命令使用；生产 managed plan 在 prepare/revalidate
        // 已被限定为 UUID。fallback 仍稳定防重，不开放新的命令能力。
        return ([item.kind.rawValue, item.executable] + item.args).joined(separator: "\u{1F}")
    }

    private static func canonicalManagedIdentifier(_ identifier: String) -> String {
        UUID(uuidString: identifier)?.uuidString.lowercased() ?? identifier.lowercased()
    }

    private static func isUnambiguousAbsoluteResourceURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return isUnambiguousAbsolutePath(url.path)
    }

    private static func isUnambiguousAbsolutePath(_ path: String) -> Bool {
        // v2026.09.20：与 runtime 解码共用纯词法合同；复核不得因已挂载的
        // /private 路径被 Foundation 规范化而误拒绝冻结计划。
        SimctlResourcePath(rawValue: path) != nil
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

    /// 默认权威 Booted-device 探针。每个 item 都由 executor 在 Process.run 前调用；
    /// 任何 query/JSON failure 都会 fail closed 为 verificationUnavailable。
    public static let defaultBootedDeviceProbe: BootedDeviceProbe = {
        SimctlBootedDeviceProbe().probe()
    }

    public static let defaultManagedResourceAuthorityProbe: ManagedResourceAuthorityProbe = {
        identifier, kind in
        SimctlManagedResourceAuthorityProbe().presence(of: identifier, kind: kind)
    }
}
