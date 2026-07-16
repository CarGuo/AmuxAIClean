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

        public var displayName: String {
            switch self {
            case .flushQuickLookCache:   return "清理 QuickLook 缓存"
            case .flushDNSCache:         return "刷新 DNS 缓存"
            }
        }

        /// 给 UI 用的解释：什么时候点这个、点了会发生什么。
        public var subtitle: String {
            switch self {
            case .flushQuickLookCache:
                return "Finder 预览图发白或不更新时执行"
            case .flushDNSCache:
                return "网站解析到旧 IP 时执行（无害）"
            }
        }
    }

    public struct Outcome: Sendable, Hashable {
        public let task: Task
        public let succeeded: Bool
        public let log: String

        public init(task: Task, succeeded: Bool, log: String) {
            self.task = task
            self.succeeded = succeeded
            self.log = log
        }
    }

    public let runner: MaintenanceCommandRunning

    public init(runner: MaintenanceCommandRunning = DefaultMaintenanceRunner()) {
        self.runner = runner
    }

    /// 单任务调度。
    public func run(_ task: Task) -> Outcome {
        GSYLog.info(.app, "MaintenanceTasks 执行 task=\(task)")
        switch task {
        case .flushQuickLookCache:
            return execute(task: task, command: Self.qlmanageCommand)
        case .flushDNSCache:
            return execute(task: task, command: Self.dnsFlushCommand)
        }
    }

    /// 批量调度（顺序执行，互不阻塞）。
    public func runAll(_ tasks: [Task] = Task.allCases) -> [Outcome] {
        tasks.map { run($0) }
    }

    private func execute(task: Task, command: MaintenanceCommand) -> Outcome {
        let result = runner.execute(command)
        let ok = result.exitCode == 0
        if !ok {
            GSYLog.warning(.app,
                "MaintenanceTasks 失败 task=\(task) exit=\(result.exitCode) log=\(result.output.prefix(200))")
        }
        return Outcome(task: task, succeeded: ok, log: result.output)
    }

    // MARK: - 命令定义（独立 static，便于测试观测）

    static let qlmanageCommand = MaintenanceCommand(
        launchPath: "/usr/bin/qlmanage",
        arguments: ["-r"])

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
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
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
            outputLimitPerStream: SubprocessExecutor.outputCaptureLimitPerStream
        )
        switch result.terminal {
        case .exited(let rawStatus):
            return MaintenanceCommandResult(
                exitCode: OwnedChildProcessExecutor.decodedExitStatus(rawStatus),
                output: result.output
            )
        case .timedOut:
            return MaintenanceCommandResult(
                exitCode: -2,
                output: "timeout after \(timeout)s; partial=\(result.output)"
            )
        case .notOwned:
            return MaintenanceCommandResult(
                exitCode: -1,
                output: "child ownership lost before terminal status; \(result.output)"
            )
        case .launchFailed(let message):
            return MaintenanceCommandResult(exitCode: -1, output: message)
        }
    }
}
