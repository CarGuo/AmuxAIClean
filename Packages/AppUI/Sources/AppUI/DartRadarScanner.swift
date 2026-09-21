import Foundation
import LogKit

protocol DartProjectChecking: Sendable {
    func fileExists(at path: String) -> Bool
}

struct DartProjectChecker: DartProjectChecking {
    func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

/// 雷达读取「墙上时间」与采样间隔等待的唯一边界。
///
/// 生产用真实时间；抽成协议是为了让瞬时 CPU 这种「时间差分」计算在测试里可以注入
/// 完全确定的假时间，避免依赖真实睡眠的调度误差而产生不稳定断言。
protocol RadarTiming: Sendable {
    func nowNanoseconds() -> UInt64
    func sleep(nanoseconds: UInt64) async throws
}

struct SystemRadarTiming: RadarTiming {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Dart 雷达扫描器。
///
/// 三类数据来自三个可靠边界，刻意不用会失真的 `ps %cpu/%mem/rss`：
///   - 进程清单（pid/ppid/uid/命令行）来自 `ps`；
///   - 内存「物理足迹」与活动监视器同口径，来自系统特权程序 `top`（含被压缩内存）；
///   - 瞬时 CPU 由内核 `proc_pidinfo(PROC_PIDTASKINFO)` 的累计 CPU 时间差分得到。
///
/// 身份冻结仍沿用两次快照 + PID/UID/可执行路径/启动时间核对，避免 PID 复用误伤。
/// CPU 时间在一次扫描内部采样两次（间隔固定 1 秒）再做差分，因此任何时刻打开
/// 雷达都能立刻得到真实瞬时 CPU，不依赖上一轮扫描是否存在。
public actor DartRadarScanner {
    private let processController: any ProcessControlling
    private let cpuSampler: any ProcessCPUSampling
    private let commandRunner: any ProcessCommandRunning
    private let projectChecker: DartProjectChecking
    private let timing: RadarTiming
    private let verificationPolicy: ProcessTerminationVerificationPolicy

    public init() {
        let controller = DarwinProcessController()
        self.processController = controller
        self.cpuSampler = controller
        self.commandRunner = ProcessProductionCommandRunner()
        self.projectChecker = DartProjectChecker()
        self.timing = SystemRadarTiming()
        self.verificationPolicy = .production
    }

    init(
        processController: any ProcessControlling,
        cpuSampler: any ProcessCPUSampling,
        commandRunner: any ProcessCommandRunning,
        projectChecker: DartProjectChecking,
        timing: RadarTiming = SystemRadarTiming(),
        verificationPolicy: ProcessTerminationVerificationPolicy = .production
    ) {
        self.processController = processController
        self.cpuSampler = cpuSampler
        self.commandRunner = commandRunner
        self.projectChecker = projectChecker
        self.timing = timing
        self.verificationPolicy = verificationPolicy
    }

    public typealias Outcome = SnapshotOutcome<DartProcessEntry, ProcessSnapshotFailure>

    private enum CPU {
        /// 两次 CPU 时间采样之间的固定间隔。间隔太短噪声大，太长刷新迟钝；1 秒与活动
        /// 监视器的采样节奏一致。
        static let sampleGapNanoseconds: UInt64 = 1_000_000_000
    }

    public func scan() async -> Outcome {
        let firstTable: [Int32: DartRawProcess]
        switch await processTable() {
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        case .success(let table): firstTable = table
        }

        let candidates = firstTable.values.compactMap { row -> (DartRawProcess, DartProcessRole)? in
            guard let role = DartRadarParser.classify(row.arguments) else { return nil }
            return (row, role)
        }
        guard !candidates.isEmpty else {
            return .success([])
        }

        let candidatePIDs = Set(candidates.map(\.0.pid))
        guard let frozenIdentities = await identitySnapshot(for: candidatePIDs) else {
            return .cancelled
        }

        let displayTable: [Int32: DartRawProcess]
        switch await processTable() {
        case .failure(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        case .success(let table): displayTable = table
        }

        var stable: [(raw: DartRawProcess, identity: ProcessIdentity, role: DartProcessRole)] = []
        for (candidate, role) in candidates {
            guard let liveRow = displayTable[candidate.pid],
                  let frozen = frozenIdentities[candidate.pid] else { continue }
            if case .found(let current) = await processController.identity(for: candidate.pid),
               current == frozen {
                stable.append((liveRow, current, role))
            }
        }
        guard !stable.isEmpty else { return .success([]) }

        let stablePIDs = Set(stable.map(\.raw.pid))
        let footprints = await physicalFootprints(for: stablePIDs)
        let workingDirectories = await workingDirectories(for: stablePIDs)
        let cpuPercentages = await instantaneousCPU(for: stablePIDs)

        var entries: [DartProcessEntry] = []
        for item in stable {
            let pid = item.raw.pid
            let (projectPath, projectName) = resolveProject(
                raw: item.raw,
                workingDirectory: workingDirectories[pid]
            )
            let (launcher, parentName) = DartRadarParser.resolveLauncher(
                for: pid,
                processTable: displayTable
            )
            entries.append(DartProcessEntry(
                pid: pid,
                ppid: item.raw.ppid,
                role: item.role,
                cpuPercent: cpuPercentages[pid] ?? 0,
                memoryBytes: footprints[pid] ?? 0,
                executablePath: item.identity.executablePath,
                arguments: item.raw.arguments,
                workingDirectory: workingDirectories[pid],
                projectPath: projectPath,
                projectName: projectName,
                launcher: launcher,
                parentName: parentName,
                identity: item.identity
            ))
        }
        return .success(entries.sorted(by: DartProcessRanking.byLoad))
    }

    public func kill(identities: [ProcessIdentity]) async -> [ProcessKillResult] {
        await ProcessTerminationExecutor.terminate(
            identities: identities,
            processController: processController,
            verificationPolicy: verificationPolicy
        )
    }

    private enum TableResult: Sendable {
        case success([Int32: DartRawProcess])
        case failure(ProcessSnapshotFailure)
        case cancelled
    }

    private func processTable() async -> TableResult {
        let output = await commandRunner.run(
            "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,uid=,command="],
            timeout: 8
        )
        if Task.isCancelled { return .cancelled }
        if let failure = processFailure(output) { return .failure(failure) }
        var table: [Int32: DartRawProcess] = [:]
        for row in DartRadarParser.parseProcessTable(output.stdout) {
            table[row.pid] = row
        }
        return .success(table)
    }

    private func identitySnapshot(
        for pids: Set<Int32>
    ) async -> [Int32: ProcessIdentity]? {
        var snapshot: [Int32: ProcessIdentity] = [:]
        for pid in pids.sorted() {
            if Task.isCancelled { return nil }
            if case .found(let identity) = await processController.identity(for: pid) {
                snapshot[pid] = identity
            }
        }
        return snapshot
    }

    /// 用系统 `top` 精确读取目标 PID 的物理足迹。`top -pid` 只输出指定进程，
    /// 不受“仅前 N 个进程”限制；任何非完整成功都整批返回空表，避免混入缺值。
    private func physicalFootprints(for pids: Set<Int32>) async -> [Int32: Int64] {
        guard !pids.isEmpty else { return [:] }
        var arguments = ["-l", "1", "-stats", "pid,command,mem"]
        for pid in pids.sorted() {
            arguments += ["-pid", String(pid)]
        }
        let output = await commandRunner.run("/usr/bin/top", arguments: arguments, timeout: 8)
        guard output.isCompleteSuccess else { return [:] }
        return DartRadarParser.parseFootprints(output.stdout)
    }

    /// 工作目录是可选增强。一次批量 lsof 取得；任何超时、截断或非零退出都整批返回空表。
    private func workingDirectories(for pids: Set<Int32>) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let pidList = pids.sorted().map(String.init).joined(separator: ",")
        let output = await commandRunner.run(
            "/usr/sbin/lsof",
            arguments: ["-a", "-d", "cwd", "-Fn", "-p", pidList],
            timeout: 6
        )
        guard output.isCompleteSuccess else {
            if !output.stderr.isEmpty {
                GSYLog.info(.operation, "dart radar cwd enrichment unavailable")
            }
            return [:]
        }
        return DartRadarParser.parseWorkingDirectories(output.stdout)
    }

    /// 在一次扫描内对每个目标读取两次累计 CPU 时间，中间等待固定 1 秒后做差分。
    /// 百分比按单核归一，多线程满载可超过 100%，与活动监视器口径一致。
    private func instantaneousCPU(for pids: Set<Int32>) async -> [Int32: Double] {
        let first = await cpuSnapshot(for: pids)
        if Task.isCancelled { return [:] }

        do {
            try await timing.sleep(nanoseconds: CPU.sampleGapNanoseconds)
        } catch {
            // 采样间隔被取消（如离开页面）说明本轮扫描已中止，返回空结果，不继续差分。
            return [:]
        }
        if Task.isCancelled { return [:] }

        let startWall = first.wallTime
        let second = await cpuSnapshot(for: pids)
        let endWall = second.wallTime

        var result: [Int32: Double] = [:]
        guard endWall > startWall else { return [:] }
        let wallDelta = Double(endWall - startWall)
        for pid in pids {
            guard let startTimes = first.values[pid],
                  let endTimes = second.values[pid],
                  endTimes.totalNanoseconds >= startTimes.totalNanoseconds else {
                result[pid] = 0
                continue
            }
            let cpuDelta = Double(endTimes.totalNanoseconds - startTimes.totalNanoseconds)
            result[pid] = min((cpuDelta / wallDelta) * 100, 100_000)
        }
        return result
    }

    private struct CPUSnapshot {
        let wallTime: UInt64
        let values: [Int32: ProcessCPUTimes]
    }

    private func cpuSnapshot(for pids: Set<Int32>) async -> CPUSnapshot {
        var values: [Int32: ProcessCPUTimes] = [:]
        for pid in pids.sorted() {
            if Task.isCancelled { break }
            if case .found(let times) = await cpuSampler.cpuTimes(for: pid) {
                values[pid] = times
            }
        }
        return CPUSnapshot(wallTime: timing.nowNanoseconds(), values: values)
    }

    private func resolveProject(
        raw: DartRawProcess,
        workingDirectory: String?
    ) -> (path: String?, name: String?) {
        let configPaths = DartRadarParser.packageConfigPaths(raw.arguments)
        for configPath in configPaths {
            guard !DartRadarParser.isToolchainReference(configPath),
                  let root = DartRadarParser.projectRoot(forPackageConfig: configPath),
                  projectChecker.fileExists(at: root + "/pubspec.yaml") else {
                continue
            }
            return (root, projectName(for: root))
        }

        if let workingDirectory,
           let root = nearestProjectRoot(from: workingDirectory) {
            return (root, projectName(for: root))
        }
        return (nil, nil)
    }

    private func nearestProjectRoot(from path: String) -> String? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        let home = NSHomeDirectory()
        while url.path.hasPrefix(home) {
            if projectChecker.fileExists(at: url.appendingPathComponent("pubspec.yaml").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    private func projectName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func processFailure(_ output: ProcessSubprocessOutput) -> ProcessSnapshotFailure? {
        if output.timedOut { return .timedOut(command: .ps) }
        if output.truncatedStreams.contains(.stdout) {
            return .outputTruncated(command: .ps)
        }
        if output.status == -1 { return .launchFailed(command: .ps) }
        if output.status != 0 { return .commandFailed(command: .ps) }
        return nil
    }
}
