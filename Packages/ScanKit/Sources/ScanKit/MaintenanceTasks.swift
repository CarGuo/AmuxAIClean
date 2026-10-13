import Foundation
import LogKit

/// Mole 对齐 M3-T5：维护任务（全 user-space，不要求 sudo）。
///
/// 对标 Mole `optimize/maintenance.sh` + `clean/launch_services.sh`，
/// 但**坚守 SOLO Mac App 边界**：
///   - 不调任何需要 sudo / SystemAdministration / root 的命令
///   - 不动 SIP-protected 路径
///   - release 路径启动子进程前先经 SafetyEngine 审计 ✓
///
/// 2 个开箱即用任务（每个都可独立调度，互不依赖）：
///   - `.flushQuickLookCache`    — Finder 预览图变白 / 不刷新缩略图时用
///   - `.flushDNSCache`          — Safari / Chrome DNS 漂移到旧 IP 时用
///
/// **不**做的事（明确划清边界）：
///   - 重建 Spotlight 索引（`mdutil -E`）—— 那是 sudo 操作
///   - 清字体缓存（`atsutil databases -remove`）—— 那也是 sudo
///   - 重置打印队列 / TCC —— 系统级 / 风险高
public struct MaintenanceTasks: Sendable {

    public enum Task: Sendable, Hashable, CaseIterable {
        case flushQuickLookCache
        case flushDNSCache
    }

    public struct Outcome: Sendable, Hashable {
        /// v2026.07.18：用户可见结果只保留稳定语义。命令 stdout/stderr、launch error
        /// 和 owned-child 诊断仍写结构化日志，但不得直接进入主界面。
        public enum Status: Sendable, Hashable {
            case succeeded
            case exited(code: Int32)
            case timedOut
            case cancelled
            case ownershipLost
            case launchFailed
        }

        public let task: Task
        public let status: Status
        /// 仅供结构化日志/技术诊断；View 不得把它当用户文案。
        public let diagnosticOutput: String

        public init(task: Task, status: Status, diagnosticOutput: String) {
            self.task = task
            self.status = status
            self.diagnosticOutput = diagnosticOutput
        }

        public var succeeded: Bool { status == .succeeded }
    }

    public let runner: MaintenanceCommandRunning

    public init(runner: MaintenanceCommandRunning = DefaultMaintenanceRunner()) {
        self.runner = runner
    }

    /// 单任务调度。
    public func run(_ task: Task) -> Outcome {
        AmuxLog.info(.app, "MaintenanceTasks 执行 task=\(task)")
        switch task {
        case .flushQuickLookCache:
            return execute(task: task, command: Self.qlmanageCommand)
        case .flushDNSCache:
            return execute(task: task, command: Self.dnsFlushCommand)
        }
    }

    /// 批量调度（顺序执行，互不阻塞）。
    public func runAll(_ tasks: [Task] = Task.allCases) -> [Outcome] {
        // v2026.07.18：批量任务属于同一 UI revision。离页取消后不能继续启动下一条
        // 子进程；当前 owned child 会先收敛为 cancelled，再停止整个 batch。
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(tasks.count)
        for task in tasks {
            guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else { break }
            let outcome = run(task)
            outcomes.append(outcome)
            if outcome.status == .cancelled { break }
        }
        return outcomes
    }

    private func execute(task: Task, command: MaintenanceCommand) -> Outcome {
        let result = runner.execute(command)
        let status: Outcome.Status
        switch result.terminal {
        case .exited(let code) where code == 0:
            status = .succeeded
        case .exited(let code):
            status = .exited(code: code)
        case .timedOut:
            status = .timedOut
        case .cancelled:
            status = .cancelled
        case .ownershipLost:
            status = .ownershipLost
        case .launchFailed:
            status = .launchFailed
        }
        if status != .succeeded {
            AmuxLog.warning(.app,
                "MaintenanceTasks 失败 task=\(task) terminal=\(String(describing: result.terminal)) diagnostic=\(result.diagnosticOutput.prefix(200))")
        }
        return Outcome(task: task, status: status, diagnosticOutput: result.diagnosticOutput)
    }

    // MARK: - 命令定义（独立 static，便于测试观测）

    /// v2026.07.18: `qlmanage -r` only reloads the Generators list. The product task explicitly
    /// promises a thumbnail-cache reset, whose documented command shape is `-r cache`.
    static let qlmanageCommand = MaintenanceCommand(
        launchPath: "/usr/bin/qlmanage",
        arguments: ["-r", "cache"])

    static let dnsFlushCommand = MaintenanceCommand(
        launchPath: "/usr/bin/dscacheutil",
        arguments: ["-flushcache"])
}

// MARK: - Runner

public struct MaintenanceCommand: Sendable, Hashable {
    public let launchPath: String
    public let arguments: [String]

    public init(launchPath: String, arguments: [String]) {
        self.launchPath = launchPath
        self.arguments = arguments
    }
}

public struct MaintenanceCommandResult: Sendable, Hashable {
    public enum Terminal: Sendable, Hashable {
        case exited(code: Int32)
        case timedOut
        case cancelled
        case ownershipLost
        case launchFailed
    }

    public let terminal: Terminal
    /// 原始 stdout/stderr/系统诊断，仅允许进入技术日志或显式技术详情。
    public let diagnosticOutput: String

    public init(terminal: Terminal, diagnosticOutput: String) {
        self.terminal = terminal
        self.diagnosticOutput = diagnosticOutput
    }
}

public protocol MaintenanceCommandRunning: Sendable {
    func execute(_ command: MaintenanceCommand) -> MaintenanceCommandResult
}

/// 生产 runner —— owned-child 执行，30s 超时。
public struct DefaultMaintenanceRunner: MaintenanceCommandRunning {

    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func execute(_ command: MaintenanceCommand) -> MaintenanceCommandResult {
        // SAFETY v2026.07.16：旧 `Process.isRunning → terminate()` 同样允许 Foundation
        // 在检查后先 reap，再用缓存 PID 发信号；共用 ScanKit 的唯一 waitpid owner 后，
        // ECHILD 永不 signal，stdout/stderr 也从启动起并行排空，不再有 wait-then-read
        // 填满 pipe 的死锁。维护命令仍保持原有 -1 launch / -2 timeout 终态合同。
        let result = OwnedChildProcessExecutor.run(
            path: command.launchPath,
            arguments: command.arguments,
            timeout: timeout,
            outputLimitPerStream: SubprocessExecutor.outputCaptureLimitPerStream,
            isCancelled: {
                // v2026.07.18：UI Task cancellation must reach the sole waitpid owner. Without
                // this bridge `.cancelled` existed only in the enum and the child kept running.
                withUnsafeCurrentTask { $0?.isCancelled ?? false }
            }
        )
        switch result.terminal {
        case .exited(let rawStatus):
            return MaintenanceCommandResult(
                terminal: .exited(code: OwnedChildProcessExecutor.decodedExitStatus(rawStatus)),
                diagnosticOutput: result.output
            )
        case .timedOut:
            return MaintenanceCommandResult(
                terminal: .timedOut,
                diagnosticOutput: result.output
            )
        case .cancelled:
            return MaintenanceCommandResult(
                terminal: .cancelled,
                diagnosticOutput: result.output
            )
        case .notOwned:
            return MaintenanceCommandResult(
                terminal: .ownershipLost,
                diagnosticOutput: result.output
            )
        case .launchFailed(let message):
            return MaintenanceCommandResult(
                terminal: .launchFailed,
                diagnosticOutput: message
            )
        }
    }
}
