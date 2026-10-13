import Foundation
import Darwin

/// 受限子进程执行器（v1.7 M1 PR-2）。
///
/// 与既有 [DefaultMaintenanceRunner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/MaintenanceTasks.swift#L137-L171) 的区别：
/// - MaintenanceRunner：管理任务（lsregister/qlmanage/dscacheutil），全是系统维护命令，硬编码 launchPath 已隔离风险
/// - SubprocessExecutor：**面向 simctl / xcrun 等开发者命令**，要执行的子命令是「数据驱动」的，
///   必须用 **allowlist** 强约束才能避免被未来 PR 误用为"任意命令执行通道"。
///
/// 设计原则：
/// 1. **白名单优先**：调用方传入 `(executable, args)`，如不在 allowlist 中直接 throw `notAllowed`；
///    任何"开后门让 caller 跳过白名单"的修改都是回归红线。
/// 2. **按命令生命周期等待**：只读查询默认 5s 超时并可终止；系统托管的破坏性操作必须
///    显式使用 `.waitUntilExit`，避免 App 在 CoreSimulator 正提交卸载时发送 TERM/KILL。
/// 3. **stdout/stderr 合并**：返回单一字符串，调用方自己解析；
///    这与 MaintenanceCommandResult 模式一致，避免 Pipe 多通道复杂度。
/// 4. **dryRun 闸门**：构造时可指定 `dryRun=true`，此时**不真起 Process**，
///    仅返回 `(exitCode: 0, output: "<dryRun> /xxx args...")` 用于测试 + 用户预览。
/// 5. **不抛异常的错误返回**：`SubprocessResult.exitCode = -1` 表 launch 失败，`-2` 表超时，
///    与 MaintenanceCommandResult 完全同构，方便调用方统一处理。
public struct SubprocessExecutor: Sendable {

    /// 子进程终态等待策略。
    ///
    /// **v2026.07.15 根因修复**：查询命令需要有界超时，防止扫描永久挂起；但
    /// `simctl delete` / `simctl runtime delete` 是 CoreSimulator 管理的事务，任意固定
    /// 秒数后强杀既无法证明回滚，也与 UI“当前项安全完成后停止”的承诺冲突。因此 managed
    /// operation 使用 `.waitUntilExit`，停止按钮只阻止提交下一项，不中断当前系统事务。
    public enum TerminalWaitPolicy: Sendable, Equatable {
        case timeout(TimeInterval)
        case waitUntilExit
    }

    /// 允许执行的命令模板。
    ///
    /// `(executable, argsPrefix)` 两元组：
    /// - `executable`：必须精确匹配，例如 `/usr/bin/xcrun`；
    /// - `argsPrefix`：实际调用的 args 必须以此为前缀，例如 `["simctl", "delete"]` 允许
    ///   `xcrun simctl delete <UUID>` 但拒绝 `xcrun simctl install`。
    ///
    /// 维护原则：**新增条目必须经过 V12 级集成测试同步加 case**，
    /// 详见 [SubprocessExecutorTests](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Tests/ScanKitTests/SubprocessExecutorTests.swift)。
    public struct AllowEntry: Sendable, Hashable {
        public let executable: String
        public let argsPrefix: [String]

        public init(executable: String, argsPrefix: [String]) {
            self.executable = executable
            self.argsPrefix = argsPrefix
        }
    }

    /// 默认 allowlist —— v1.7 M1 PR-2 范围。
    ///
    /// 该 list 必须**只读**——任何运行时修改都是回归红线。
    public static let defaultAllowlist: [AllowEntry] = [
        // simctl 只读查询
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "list", "devices", "--json"]),
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "list", "runtimes", "--json"]),
        // 2026-07-15：新 Xcode 托管 runtime 元数据，直接提供 UUID/deletable/sizeBytes。
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "runtime", "list", "-j"]),
        // CoreSimulator 托管卸载。固定前缀之外还会在 argumentsPassDestructiveTailPolicy
        // 严格要求单个 UUID 尾参，不允许 semantic identifier 或附加 flag。
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "delete"]),
        AllowEntry(executable: "/usr/bin/xcrun", argsPrefix: ["simctl", "runtime", "delete"]),
    ]

    public enum SubprocessError: Error, Sendable, Equatable {
        /// 不在 allowlist 中。`reason` 给出 (executable, args) 便于日志追踪。
        case notAllowed(executable: String, args: [String])
    }

    public struct Result: Sendable, Hashable {
        public let exitCode: Int32
        public let output: String

        public init(exitCode: Int32, output: String) {
            self.exitCode = exitCode
            self.output = output
        }

        /// 仅当 exitCode == 0 视为成功。
        public var isSuccess: Bool { exitCode == 0 }
    }

    /// 系统托管命令的可观察生命周期。
    ///
    /// **v2026.07.16 根因修复**：`waitUntilExit` 保护 CoreSimulator 事务不被 App 强杀，
    /// 但旧 API 只能在命令退出后返回，UI 因而只能无限旋转。新的观察流把“已跨过
    /// owned spawn 提交边界”“仍在运行”“观察窗口已耗尽”和“拿到真实退出码”分开。
    /// `.stalled` 不是进程超时：执行器不会发送 TERM/KILL，后台仍等待系统事务自然结束。
    public enum ManagedExecutionUpdate: Sendable, Hashable {
        /// 紧邻 owned spawn 的最后安全复核拒绝了提交。该事件发生时没有 PID、没有
        /// 系统事务，也不能生成 destructive-operation receipt。
        case submissionRejected(ManagedSubmissionGuardDecision)
        /// `processIdentifier == nil` 仅用于 dry-run 测试；生产提交一定有 PID。
        case submitted(processIdentifier: Int32?)
        case running(processIdentifier: Int32?)
        case stalled(processIdentifier: Int32, elapsed: TimeInterval)
        case confirmedTerminal(Result)
    }

    /// Managed operation 在真正跨过 owned spawn 前的最后安全判定。
    ///
    /// **v2026.07.16 根因修复**：调用方在 await 之前检查 Simulator 状态仍存在 TOCTOU
    /// 窗口。闸门闭包由执行器在无任何 suspension point 的情况下、紧邻 owned spawn
    /// 调用；失败时 fail closed，绝不启动子进程。
    public enum ManagedSubmissionGuardDecision: Sendable, Hashable {
        case allow
        case blocked
        case verificationUnavailable
        /// 持久 tombstone 对应的资源仍在权威清单中，禁止跨重启重复提交。
        case persistentPendingOperation
        /// 权威清单已确认 tombstone 对应资源消失；本次不再提交，要求 UI 重扫对账。
        case resourceAlreadyAbsent
    }

    public typealias ManagedSubmissionGuard = @Sendable () -> ManagedSubmissionGuardDecision

    /// owned spawn 前的最后一个持久状态屏障。
    ///
    /// **v2026.07.16 根因修复**：安全闸只负责 reserve 还不够；调用方必须先把持久
    /// tombstone 提升为 submitted，执行器才可启动进程。返回 false 时本方法发布
    /// verificationUnavailable 且绝不启动子进程，避免 ledger 阶段与真实提交
    /// 边界发生静默分叉。
    public typealias ManagedSubmissionPersistenceBarrier = @Sendable () -> Bool

    /// stdout/stderr 各自最多保留的诊断字节数。pipe reader 仍会持续读取并丢弃
    /// 超出部分，避免 pipe 反压卡死子进程，同时避免异常命令无限吃掉 App 内存。
    static let outputCaptureLimitPerStream = 64 * 1_024

    public let allowlist: [AllowEntry]
    public let terminalWaitPolicy: TerminalWaitPolicy
    public let dryRun: Bool

    public init(allowlist: [AllowEntry] = SubprocessExecutor.defaultAllowlist,
                timeout: TimeInterval = 5,
                dryRun: Bool = false) {
        self.allowlist = allowlist
        self.terminalWaitPolicy = .timeout(timeout)
        self.dryRun = dryRun
    }

    /// 系统托管事务专用构造入口。调用点必须显式选择等待策略，不能靠扩大 magic timeout
    /// 猜测 Runtime 卸载需要多久。
    public init(allowlist: [AllowEntry] = SubprocessExecutor.defaultAllowlist,
                terminalWaitPolicy: TerminalWaitPolicy,
                dryRun: Bool = false) {
        self.allowlist = allowlist
        self.terminalWaitPolicy = terminalWaitPolicy
        self.dryRun = dryRun
    }

    /// 执行子进程。
    ///
    /// - Parameters:
    ///   - executable: 绝对可执行路径，如 `/usr/bin/xcrun`
    ///   - args: 完整参数列表，如 `["simctl", "delete", "<UUID>"]`
    /// - Throws: `SubprocessError.notAllowed` 若不在 allowlist
    /// - Returns: `Result(exitCode, output)`；`exitCode = -1` 表 launch 失败，`-2` 表超时
    ///
    /// **Threading 警告**：本函数是**同步阻塞**的——会在当前线程一直阻塞到
    /// 子进程结束或有界查询的 `timeout` 触发。caller 若在 actor / @MainActor 上下文里调用，
    /// 会持锁阻塞整个 actor。已知 actor 调用方：
    /// [SimctlDevicesScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlDevicesScanner.swift)
    /// 与 [SimctlRuntimeScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/SimctlRuntimeScanner.swift)
    /// ——这两个 actor 串行使用 executor，外部不会并发等同一 actor，可接受。
    /// `.waitUntilExit` 必须在 nonisolated / detached 上下文调用，避免阻塞主线程或核心 actor。
    public func run(executable: String, args: [String]) throws -> Result {
        try runInternal(
            executable: executable,
            args: args,
            managedStallAfter: nil,
            onManagedUpdate: nil,
            preSubmissionGuard: nil,
            preLaunchPersistenceBarrier: nil
        )
    }

    /// 启动一个不会被观察窗口强杀的系统托管命令，并返回有序生命周期流。
    ///
    /// 调用方可以在 `.stalled` 后停止消费，把结果标记为 unknown 并稍后通过权威扫描
    /// 对账；生产者会继续持有 owned child/Pipe，直到 CoreSimulator 自己返回真实终态。
    /// 该 API 只允许 `.waitUntilExit`，查询命令仍使用同步 `run` 的有界 timeout。
    public func observeManagedExecution(
        executable: String,
        args: [String],
        stallAfter: TimeInterval,
        preSubmissionGuard: ManagedSubmissionGuard? = nil,
        preLaunchPersistenceBarrier: ManagedSubmissionPersistenceBarrier? = nil
    ) throws -> AsyncStream<ManagedExecutionUpdate> {
        precondition(stallAfter.isFinite && stallAfter > 0, "stallAfter must be finite and positive")
        precondition(
            dryRun || terminalWaitPolicy == .waitUntilExit,
            "Managed execution observation requires waitUntilExit"
        )
        // 同步校验后才创建 detached producer，确保 allowlist/UUID 拒绝仍发生在提交前，
        // 不会出现“流已返回但其实永远不会执行”的模糊状态。
        try validate(executable: executable, args: args)

        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            Task.detached(priority: .userInitiated) { [self] in
                do {
                    let result = try runInternal(
                        executable: executable,
                        args: args,
                        managedStallAfter: stallAfter,
                        onManagedUpdate: { update in
                            _ = continuation.yield(update)
                        },
                        preSubmissionGuard: preSubmissionGuard,
                        preLaunchPersistenceBarrier: preLaunchPersistenceBarrier
                    )
                    // -4 是执行前安全闸的内部 sentinel；对应的类型化
                    // `.submissionRejected` 已经发布，不能再伪装成子进程终态。
                    if result.exitCode != -4 {
                        _ = continuation.yield(.confirmedTerminal(result))
                    }
                } catch {
                    // allowlist 已在创建流前同步复核；若不可变 executor 在这里仍拒绝，说明
                    // 内部合同被破坏。流必须收敛，不能留给上层永久等待。
                    _ = continuation.yield(.confirmedTerminal(Result(
                        exitCode: -3,
                        output: "managed execution rejected after validation: \(error)"
                    )))
                }
                continuation.finish()
            }
        }
    }

    private func runInternal(
        executable: String,
        args: [String],
        managedStallAfter: TimeInterval?,
        onManagedUpdate: (@Sendable (ManagedExecutionUpdate) -> Void)?,
        preSubmissionGuard: ManagedSubmissionGuard?,
        preLaunchPersistenceBarrier: ManagedSubmissionPersistenceBarrier?
    ) throws -> Result {
        // 1. allowlist 检查（必须先于任何执行动作）
        try validate(executable: executable, args: args)

        // 2. dryRun 闸门：不真起进程
        if dryRun {
            if let preSubmissionGuard {
                let decision = preSubmissionGuard()
                guard decision == .allow else {
                    onManagedUpdate?(.submissionRejected(decision))
                    return Result(exitCode: -4, output: "managed submission rejected by safety guard")
                }
            }
            if let preLaunchPersistenceBarrier, !preLaunchPersistenceBarrier() {
                onManagedUpdate?(.submissionRejected(.verificationUnavailable))
                return Result(
                    exitCode: -4,
                    output: "managed submission rejected by persistence barrier"
                )
            }
            let argsJoined = args.joined(separator: " ")
            onManagedUpdate?(.submitted(processIdentifier: nil))
            onManagedUpdate?(.running(processIdentifier: nil))
            return Result(exitCode: 0, output: "<dryRun> \(executable) \(argsJoined)")
        }

        // 3. 实际执行（事件驱动 + timeout 闸门 + 双 Pipe 边读边累积）
        return runProcess(
            executable: executable,
            args: args,
            managedStallAfter: managedStallAfter,
            onManagedUpdate: onManagedUpdate,
            preSubmissionGuard: preSubmissionGuard,
            preLaunchPersistenceBarrier: preLaunchPersistenceBarrier
        )
    }

    private func validate(executable: String, args: [String]) throws {
        let isAllowed = allowlist.contains { entry in
            entry.executable == executable
            && args.count >= entry.argsPrefix.count
            && Array(args.prefix(entry.argsPrefix.count)) == entry.argsPrefix
        }
        guard isAllowed else {
            throw SubprocessError.notAllowed(executable: executable, args: args)
        }
        guard Self.argumentsPassDestructiveTailPolicy(executable: executable, args: args) else {
            throw SubprocessError.notAllowed(executable: executable, args: args)
        }
    }

    private func runProcess(
        executable: String,
        args: [String],
        managedStallAfter: TimeInterval?,
        onManagedUpdate: (@Sendable (ManagedExecutionUpdate) -> Void)?,
        preSubmissionGuard: ManagedSubmissionGuard?,
        preLaunchPersistenceBarrier: ManagedSubmissionPersistenceBarrier?
    ) -> Result {
        // **v2026.07.16 相邻重验**：安全状态必须在执行器内部、紧邻 spawn 读取；
        // 此处与下方 owned-child primitive 之间没有 await 或其它调用方代码，消除上层
        // 复核后再切回 detached producer 的 TOCTOU 窗口。
        if let preSubmissionGuard {
            let decision = preSubmissionGuard()
            guard decision == .allow else {
                onManagedUpdate?(.submissionRejected(decision))
                return Result(exitCode: -4, output: "managed submission rejected by safety guard")
            }
        }

        // **v2026.07.16 阶段屏障**：reserve 与 submitted 不再共用一个模糊 intent。
        // 屏障与下方 owned spawn 同处无 suspension 的同步调用栈；若持久转换失败，
        // 本次仍处于“明确未启动”，因此发布类型化拒绝而不是冒险提交。
        if let preLaunchPersistenceBarrier, !preLaunchPersistenceBarrier() {
            onManagedUpdate?(.submissionRejected(.verificationUnavailable))
            return Result(exitCode: -4, output: "managed submission rejected by persistence barrier")
        }

        // SAFETY v2026.07.16：查询 timeout 改由唯一 `waitpid` owner 管理。Foundation
        // 不再能先 reap 子进程；只有 `.running` 才会 TERM/KILL，`ECHILD` 后永不 signal，
        // 从根因上关闭“缓存 PID 已复用却被超时清理误杀”的窗口。两个 pipe 从 launch
        // 起持续排空并各自有界，正常、超时和 ownership-lost 都收敛到类型化终态。
        let ownedResult: OwnedChildProcessExecutor.ExecutionResult
        switch terminalWaitPolicy {
        case .waitUntilExit:
            ownedResult = OwnedChildProcessExecutor.run(
                path: executable,
                arguments: args,
                timeout: nil,
                stallAfter: managedStallAfter,
                outputLimitPerStream: Self.outputCaptureLimitPerStream,
                onSpawn: { pid in
                    onManagedUpdate?(.submitted(processIdentifier: pid))
                    onManagedUpdate?(.running(processIdentifier: pid))
                },
                onStall: { pid, elapsed in
                    onManagedUpdate?(.stalled(processIdentifier: pid, elapsed: elapsed))
                }
            )
        case .timeout(let timeout):
            ownedResult = OwnedChildProcessExecutor.run(
                path: executable,
                arguments: args,
                timeout: timeout,
                outputLimitPerStream: Self.outputCaptureLimitPerStream
            )
        }

        switch ownedResult.terminal {
        case .exited(let rawStatus):
            return Result(
                exitCode: OwnedChildProcessExecutor.decodedExitStatus(rawStatus),
                output: ownedResult.output
            )
        case .timedOut(let sentSIGKILL, _):
            let timeout: TimeInterval
            if case .timeout(let configured) = terminalWaitPolicy {
                timeout = configured
            } else {
                // Managed operations never enter the destructive timeout state.
                return Result(exitCode: -1, output: "child wait contract violated; \(ownedResult.output)")
            }
            let suffix = sentSIGKILL ? " SIGKILL sent" : " terminated"
            return Result(
                exitCode: -2,
                output: "timeout after \(timeout)s;\(suffix); partial=\(ownedResult.output)"
            )
        case .cancelled(let sentSIGKILL, _):
            // v2026.07.17：取消与 timeout / allowlist 拒绝 / 提交闸门拒绝是不同终态。
            // 当前 public run 尚未注入取消检查，但底层 owned executor 已支持；若后续
            // 调用链接入取消，不得把用户取消伪装成 timeout 或 commandRejected。
            let suffix = sentSIGKILL ? " SIGKILL sent" : " terminated"
            return Result(
                exitCode: -5,
                output: "cancelled;\(suffix); partial=\(ownedResult.output)"
            )
        case .notOwned:
            return Result(
                exitCode: -1,
                output: "child ownership lost before terminal status; \(ownedResult.output)"
            )
        case .launchFailed(let message):
            return Result(exitCode: -1, output: message)
        }
    }

    static func argumentsPassDestructiveTailPolicy(executable: String, args: [String]) -> Bool {
        guard executable == "/usr/bin/xcrun" else { return true }
        if Array(args.prefix(2)) == ["simctl", "delete"] {
            return args.count == 3 && isUUID(args[2])
        }
        if Array(args.prefix(3)) == ["simctl", "runtime", "delete"] {
            return args.count == 4 && isUUID(args[3])
        }
        return true
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

}
