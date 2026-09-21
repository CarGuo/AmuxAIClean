import Darwin
import XCTest
@testable import AppUI

final class DartRadarTests: XCTestCase {
    private func identity(
        pid: Int32,
        path: String,
        uid: UInt32 = UInt32(getuid()),
        startTime: UInt64 = 100
    ) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            uid: uid,
            executablePath: path,
            startTimeSeconds: startTime,
            startTimeMicroseconds: 7
        )
    }

    // MARK: - 进程表解析

    func test_parseProcessLine_前三列数字后命令行保留全部空格() {
        let line = "200 10 501 /Users/me/flutter/bin/dartvm --packages=/Users/me/my app/.dart_tool/package_config.json flutter_tools.snapshot run"

        let row = DartRadarParser.parseProcessLine(line)

        XCTAssertEqual(row?.pid, 200)
        XCTAssertEqual(row?.ppid, 10)
        XCTAssertEqual(row?.uid, 501)
        XCTAssertTrue(row?.arguments.contains("my app/.dart_tool") ?? false)
    }

    func test_parseProcessTable_多行解析并忽略空行() {
        let table = """

        200 10 501 /bin/dart run
        300 200 501 /bin/dartaotruntime frontend_server

        """
        let rows = DartRadarParser.parseProcessTable(table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.pid), [200, 300])
    }

    func test_parseProcessLine_压缩空格也能解析() {
        // 真实 ps 输出列间是不定数量空格。
        let row = DartRadarParser.parseProcessLine("  200   10  501 /bin/dart run")
        XCTAssertEqual(row?.pid, 200)
        XCTAssertEqual(row?.ppid, 10)
        XCTAssertEqual(row?.uid, 501)
    }

    func test_parseProcessLine_非法行返回nil而不是崩溃() {
        XCTAssertNil(DartRadarParser.parseProcessLine(""))
        XCTAssertNil(DartRadarParser.parseProcessLine("200 10 notanumber /bin/dart"))
        XCTAssertNil(DartRadarParser.parseProcessLine("200 10"))
    }

    // MARK: - 角色识别

    func test_classify_识别各种DartFlutter角色() {
        let cases: [(String, DartProcessRole)] = [
            ("/sdk/bin/dartvm flutter_tools.snapshot run", .flutterTools),
            ("/sdk/bin/dart run bin/main.dart", .dartVM),
            ("/sdk/bin/dartaotruntime frontend_server_aot.dart.snapshot", .frontendServer),
            ("/sdk/bin/dartaotruntime dds_aot.dart.snapshot", .dds),
            ("/sdk/bin/dartaotruntime devtools_aot", .devtools),
            ("/sdk/bin/dart devtools", .devtools),
            ("/engine/flutter_tester --run-forever", .flutterTester),
            ("/engine/gen_snapshot --snapshot_kind=app-aot-elf", .genSnapshot),
            ("/sdk/bin/dart mcp-server", .mcpServer),
            ("/sdk/bin/dart analysis_server.dart.snapshot", .analyzer),
            ("/usr/local/bin/puro create myenv", .puro)
        ]
        for (arguments, expected) in cases {
            XCTAssertEqual(DartRadarParser.classify(arguments), expected, "输入: \(arguments)")
        }
    }

    func test_classify_普通node和java进程不进入雷达() {
        XCTAssertNil(DartRadarParser.classify("/usr/local/bin/node scripts/dev.ts"))
        XCTAssertNil(DartRadarParser.classify("/Applications/Android Studio.app/jbr/bin/java -jar gradle.jar"))
    }

    func test_classify_路径含空格切不出首token时仍靠强信号识别() {
        // 首 token 会被空格截断，但命令行里的 flutter_tools.snapshot 是确定工件。
        let args = "/Users/me/Android Studio.app/Contents/jbr/bin/dartvm flutter_tools.snapshot build"
        XCTAssertEqual(DartRadarParser.classify(args), .flutterTools)
    }

    // MARK: --packages 提取

    func test_packageConfigPaths_兼容等号空格和fileURI三种写法并去重() {
        let arguments = """
        dartvm --packages=/a/.dart_tool/package_config.json --packages file:///b/.dart_tool/package_config.json --packages /a/.dart_tool/package_config.json
        """
        let paths = DartRadarParser.packageConfigPaths(arguments)
        XCTAssertEqual(paths, [
            "/a/.dart_tool/package_config.json",
            "/b/.dart_tool/package_config.json"
        ])
    }

    func test_packageConfigPaths_没有参数时返回空() {
        XCTAssertEqual(DartRadarParser.packageConfigPaths("dart run"), [])
    }

    func test_isToolchainReference_区分SDK内部引用和用户项目() {
        XCTAssertTrue(DartRadarParser.isToolchainReference("/sdk/flutter/bin/cache/dart-sdk/foo"))
        XCTAssertTrue(DartRadarParser.isToolchainReference("/sdk/flutter/packages/flutter_tools/x"))
        XCTAssertFalse(DartRadarParser.isToolchainReference("/Users/me/myapp/.dart_tool/package_config.json"))
    }

    func test_projectRoot_从packageConfig反推项目根() {
        XCTAssertEqual(
            DartRadarParser.projectRoot(forPackageConfig: "/Users/me/myapp/.dart_tool/package_config.json"),
            "/Users/me/myapp"
        )
        XCTAssertNil(DartRadarParser.projectRoot(forPackageConfig: "/random/path.txt"))
    }

    // MARK: 工作目录解析

    func test_parseWorkingDirectories_按pid块解析() {
        let output = """
        p200
        fcwd
        n/Users/me/myapp
        p300
        fcwd
        n/Users/me/other
        """
        let map = DartRadarParser.parseWorkingDirectories(output)
        XCTAssertEqual(map, [200: "/Users/me/myapp", 300: "/Users/me/other"])
    }

    // MARK: 物理足迹解析

    func test_parseFootprints_命令含空格时仍按首列和末列取值() {
        let output = """
        Processes: 2

        200 /sdk/bin/dartvm flutter_tools.snapshot run 50M
        300 /sdk/bin/dartaotruntime frontend_server 1.2G
        """
        let map = DartRadarParser.parseFootprints(output)
        XCTAssertEqual(map[200], 50 * 1024 * 1024)
        XCTAssertEqual(map[300], Int64(1.2 * Double(1024 * 1024 * 1024)))
    }

    func test_parseByteCount_各单位解析() {
        XCTAssertEqual(DartRadarParser.parseByteCount("100B"), 100)
        XCTAssertEqual(DartRadarParser.parseByteCount("512K"), 512 * 1024)
        XCTAssertEqual(DartRadarParser.parseByteCount("791M"), 791 * 1024 * 1024)
        XCTAssertEqual(DartRadarParser.parseByteCount("2G"), 2 * 1024 * 1024 * 1024)
    }

    func test_parseByteCount_非法输入返回nil() {
        XCTAssertNil(DartRadarParser.parseByteCount("abc"))
        XCTAssertNil(DartRadarParser.parseByteCount("10X"))
        XCTAssertNil(DartRadarParser.parseByteCount("M"))
    }

    // MARK: 启动来源归因

    func test_resolveLauncher_沿父链识别VSCode() {
        let table = table([
            (10, 1, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            (200, 10, "/sdk/bin/dartvm flutter_tools.snapshot run"),
            (300, 200, "/sdk/bin/dartaotruntime frontend_server")
        ])
        let result = DartRadarParser.resolveLauncher(for: 300, processTable: table)
        XCTAssertEqual(result.launcher, .vsCode)
        XCTAssertEqual(result.parentName, "dartvm")
    }

    func test_resolveLauncher_识别终端shell() {
        let table = table([
            (20, 1, "/bin/zsh -l"),
            (300, 20, "/sdk/bin/dart run bin/main.dart")
        ])
        let result = DartRadarParser.resolveLauncher(for: 300, processTable: table)
        XCTAssertEqual(result.launcher, .terminal)
    }

    func test_resolveLauncher_直接由launchd托管归为工具链() {
        let table = table([
            (1, 0, "/sbin/launchd"),
            (300, 1, "/sdk/bin/dart mcp-server")
        ])
        let result = DartRadarParser.resolveLauncher(for: 300, processTable: table)
        XCTAssertEqual(result.launcher, .toolchain)
    }

    func test_resolveLauncher_未知外部进程保留其名字且防环() {
        // 构造环 400 -> 401 -> 400，外部进程名为 weird-host；不能无限循环。
        let table = table([
            (400, 401, "/usr/bin/weird-host worker"),
            (401, 400, "/usr/bin/weird-host supervisor"),
            (300, 400, "/sdk/bin/dart run")
        ])
        let result = DartRadarParser.resolveLauncher(for: 300, processTable: table)
        guard case .other(let name) = result.launcher else {
            return XCTFail("期望 .other，得到 \(result.launcher)")
        }
        XCTAssertEqual(name, "weird-host")
    }

    func test_resolveLauncher_表中缺失返回unknown() {
        let result = DartRadarParser.resolveLauncher(for: 999, processTable: [:])
        XCTAssertEqual(result.launcher, .unknown)
        XCTAssertNil(result.parentName)
    }

    // MARK: 项目归档分组

    func test_projectGrouper_按项目路径聚合并把无项目进程放入未归属() {
        let entries = sampleEntries([
            (200, "/Users/me/appA", 10, 100),
            (201, "/Users/me/appA", 5, 50),
            (300, "/Users/me/appB", 40, 200),
            (400, nil, 1, 10)
        ])
        let groups = DartProjectGrouper.groups(from: entries)

        XCTAssertEqual(groups.count, 3)
        // 组按总 CPU 降序：appB(40) > appA(15) > 未归属(1)
        XCTAssertEqual(groups.map(\.id), ["/Users/me/appB", "/Users/me/appA", DartProjectGrouper.unassignedID])
        XCTAssertEqual(groups[1].title, "appA")
        XCTAssertEqual(groups[1].entries.map(\.pid), [200, 201])
        XCTAssertEqual(groups[1].cpuTotal, 15)
        XCTAssertTrue(groups[2].isUnassigned)
    }

    func test_projectGrouper_空输入返回空() {
        XCTAssertTrue(DartProjectGrouper.groups(from: []).isEmpty)
    }

    // MARK: - 扫描器端到端

    private let userProjectConfig = "/Users/me/myapp/.dart_tool/package_config.json"

    func test_scan_完整快照冻结身份并完成项目与启动者归因() async {
        let psTable = """
        10 1 501 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
        200 10 501 /sdk/bin/dartvm --packages=\(userProjectConfig) flutter_tools.snapshot run
        300 200 501 /sdk/bin/dartaotruntime frontend_server_aot --packages \(userProjectConfig)
        """
        let psOutput = ProcessSubprocessOutput(stdout: psTable, stderr: "", status: 0, timedOut: false)
        let cwdOutput = ProcessSubprocessOutput(
            stdout: """
            p200
            fcwd
            n/Users/me/myapp
            p300
            fcwd
            n/Users/me/myapp
            """,
            stderr: "",
            status: 0,
            timedOut: false
        )
        let topOutput = ProcessSubprocessOutput(
            stdout: """
            200 /sdk/bin/dartvm run 50M
            300 /sdk/bin/dartaotruntime frontend_server 20M
            """,
            stderr: "",
            status: 0,
            timedOut: false
        )
        let runner = DartCommandRunnerStub(outputs: [
            "/bin/ps": [psOutput, psOutput],
            "/usr/sbin/lsof": [cwdOutput],
            "/usr/bin/top": [topOutput]
        ])
        let identities = [
            Int32(200): identity(pid: 200, path: "/sdk/bin/dartvm"),
            Int32(300): identity(pid: 300, path: "/sdk/bin/dartaotruntime")
        ]
        let controller = DartProcessControllerStub(identities: identities)
        let checker = FakeProjectChecker(existingFiles: ["/Users/me/myapp/pubspec.yaml"])
        let scanner = DartRadarScanner(
            processController: controller,
            cpuSampler: ConstantCPUSampler(),
            commandRunner: runner,
            projectChecker: checker
        )

        let outcome = await scanner.scan()
        let entries = successEntries(outcome)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.pid), [200, 300]) // CPU 相同，按内存降序
        XCTAssertEqual(entries[0].role, .flutterTools)
        XCTAssertEqual(entries[1].role, .frontendServer)
        for entry in entries {
            XCTAssertEqual(entry.launcher, .vsCode)
            XCTAssertEqual(entry.projectPath, "/Users/me/myapp")
            XCTAssertEqual(entry.projectName, "myapp")
            XCTAssertTrue(entry.canTerminate)
        }
        XCTAssertEqual(entries[0].memoryBytes, 50 * 1024 * 1024)
        XCTAssertEqual(entries[1].memoryBytes, 20 * 1024 * 1024)
    }

    func test_scan_CPU时间增长时按差分得到真实占用() async {
        let psTable = """
        1 0 0 /sbin/launchd
        200 1 501 /sdk/bin/dart run bin/main.dart
        """
        let psOutput = ProcessSubprocessOutput(stdout: psTable, stderr: "", status: 0, timedOut: false)
        let runner = DartCommandRunnerStub(outputs: [
            "/bin/ps": [psOutput, psOutput],
            "/usr/bin/top": [ProcessSubprocessOutput(
                stdout: "200 /sdk/bin/dart run 100M",
                stderr: "",
                status: 0,
                timedOut: false
            )]
        ])
        let controller = DartProcessControllerStub(identities: [
            200: identity(pid: 200, path: "/sdk/bin/dart")
        ])
        let scanner = DartRadarScanner(
            processController: controller,
            // 采样间隔 1 秒，CPU 时间增加 0.5 秒 → 50%。
            cpuSampler: SteppingCPUSampler(start: 1_000_000_000, increment: 500_000_000),
            commandRunner: runner,
            projectChecker: FakeProjectChecker(existingFiles: []),
            timing: SteppingRadarTiming(elapsedPerSleep: 1_000_000_000)
        )

        let entries = successEntries(await scanner.scan())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].cpuPercent, 50, accuracy: 2)
    }

    func test_scan_没有候选进程时是空成功() async {
        let psTable = """
        1 0 0 /sbin/launchd
        50 1 501 /usr/local/bin/node server.js
        """
        let psOutput = ProcessSubprocessOutput(stdout: psTable, stderr: "", status: 0, timedOut: false)
        let runner = DartCommandRunnerStub(outputs: ["/bin/ps": [psOutput]])
        let scanner = DartRadarScanner(
            processController: DartProcessControllerStub(identities: [:]),
            cpuSampler: ConstantCPUSampler(),
            commandRunner: runner,
            projectChecker: FakeProjectChecker(existingFiles: [])
        )
        let outcome = await scanner.scan()
        guard case .success(let entries) = outcome else {
            return XCTFail("期望空成功，得到 \(outcome)")
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func test_scan_ps命令失败投影为类型化失败并保留命令来源() async {
        let failed = ProcessSubprocessOutput(stdout: "", stderr: "boom", status: 1, timedOut: false)
        let runner = DartCommandRunnerStub(outputs: ["/bin/ps": [failed]])
        let scanner = DartRadarScanner(
            processController: DartProcessControllerStub(identities: [:]),
            cpuSampler: ConstantCPUSampler(),
            commandRunner: runner,
            projectChecker: FakeProjectChecker(existingFiles: [])
        )
        let outcome = await scanner.scan()
        guard case .failure(let failure) = outcome else {
            return XCTFail("期望失败，得到 \(outcome)")
        }
        XCTAssertEqual(failure, .commandFailed(command: .ps))
        XCTAssertFalse(failure.message(locale: Locale(identifier: "en")).contains("boom"))
    }

    func test_scan_增强项失败时整批丢弃但不影响扫描() async {
        let psTable = """
        200 1 501 /sdk/bin/dart run
        """
        let psOutput = ProcessSubprocessOutput(stdout: psTable, stderr: "", status: 0, timedOut: false)
        // lsof 超时、top 缺失：cwd 与 footprint 增强应整批为空，扫描仍返回进程。
        let badLsof = ProcessSubprocessOutput(stdout: "", stderr: "", status: -2, timedOut: true)
        let runner = DartCommandRunnerStub(outputs: [
            "/bin/ps": [psOutput, psOutput],
            "/usr/sbin/lsof": [badLsof]
        ])
        let controller = DartProcessControllerStub(identities: [
            200: identity(pid: 200, path: "/sdk/bin/dart")
        ])
        let scanner = DartRadarScanner(
            processController: controller,
            cpuSampler: ConstantCPUSampler(),
            commandRunner: runner,
            projectChecker: FakeProjectChecker(existingFiles: [])
        )
        let entries = successEntries(await scanner.scan())
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].workingDirectory)
        XCTAssertNil(entries[0].projectPath)
        XCTAssertEqual(entries[0].memoryBytes, 0)
    }

    func test_kill_委托通用执行器并返回每条结果() async {
        let target = identity(pid: 200, path: "/sdk/bin/dart")
        let controller = DartProcessControllerStub(
            identities: [200: target],
            submission: .accepted
        )
        let policy = ProcessTerminationVerificationPolicy(
            maximumWaitNanoseconds: 1_000_000,
            pollIntervalNanoseconds: 100_000
        )
        let scanner = DartRadarScanner(
            processController: controller,
            cpuSampler: ConstantCPUSampler(),
            commandRunner: DartCommandRunnerStub(outputs: [:]),
            projectChecker: FakeProjectChecker(existingFiles: []),
            verificationPolicy: policy
        )
        // stub 中进程“一直存活”，有界核对结束后应是“已发请求未确认退出”，而非谎报成功。
        let results = await scanner.kill(identities: [target])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].pid, 200)
        XCTAssertEqual(results[0].disposition, .terminationRequested)
    }

    // MARK: 辅助

    private func table(_ rows: [(Int32, Int32, String)]) -> [Int32: DartRawProcess] {
        var result: [Int32: DartRawProcess] = [:]
        for (pid, ppid, args) in rows {
            result[pid] = DartRawProcess(
                pid: pid,
                ppid: ppid,
                uid: 501,
                arguments: args
            )
        }
        return result
    }

    private func sampleEntries(_ rows: [(pid: Int32, project: String?, cpu: Double, mem: Int64)]) -> [DartProcessEntry] {
        rows.map { row in
            let path = row.project ?? "/sdk/bin/dart"
            return DartProcessEntry(
                pid: row.pid,
                ppid: 1,
                role: .dartVM,
                cpuPercent: row.cpu,
                memoryBytes: row.mem,
                executablePath: "/sdk/bin/dart",
                arguments: "/sdk/bin/dart run",
                workingDirectory: nil,
                projectPath: row.project,
                projectName: row.project?.split(separator: "/").last.map(String.init),
                launcher: .terminal,
                parentName: "zsh",
                identity: identity(pid: row.pid, path: path)
            )
        }
    }

    private func successEntries(_ outcome: DartRadarScanner.Outcome) -> [DartProcessEntry] {
        guard case .success(let entries) = outcome else {
            XCTFail("期望成功快照，得到 \(outcome)")
            return []
        }
        return entries
    }
}

private struct FakeProjectChecker: DartProjectChecking {
    let existingFiles: Set<String>

    func fileExists(at path: String) -> Bool {
        existingFiles.contains(path)
    }
}

/// 恒定 CPU 时间样本：两次采样返回相同值 → CPU 为 0，用于与 CPU 无关的扫描测试。
private actor ConstantCPUSampler: ProcessCPUSampling {
    func cpuTimes(for _: Int32) -> ProcessCPUTimesLookup {
        .found(ProcessCPUTimes(totalNanoseconds: 1_000_000_000))
    }
}

/// 按每个 PID 各自的采样次数递增：同一 PID 第一次采样返回基准、第二次返回基准+增量，
/// 不依赖全局调用顺序，因此并行或全包环境下结果稳定。用于验证差分瞬时占用。
private actor SteppingCPUSampler: ProcessCPUSampling {
    private let increment: UInt64
    private let start: UInt64
    private var callCounts: [Int32: Int] = [:]

    init(start: UInt64, increment: UInt64) {
        self.start = start
        self.increment = increment
    }

    func cpuTimes(for pid: Int32) -> ProcessCPUTimesLookup {
        let count = callCounts[pid] ?? 0
        callCounts[pid] = count + 1
        // count == 0 是第一次采样，返回基准；第二次（count == 1）返回基准 + 增量。
        let total = count == 0 ? start : start + increment
        return .found(ProcessCPUTimes(totalNanoseconds: total))
    }
}

/// 与 SteppingCPUSampler 配套的假墙上时钟：每次「睡眠」不真正等待，只把当前时间
/// 向后推进一个固定量；读取时间按推进次数返回，使时间差分计算结果完全确定。
/// 与协议的非隔离同步方法保持一致，内部计数器用 NSLock 保护。
private final class SteppingRadarTiming: RadarTiming, @unchecked Sendable {
    private let lock = NSLock()
    private let elapsedPerSleep: UInt64
    private var elapsed: UInt64 = 0

    init(elapsedPerSleep: UInt64) {
        self.elapsedPerSleep = elapsedPerSleep
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    func sleep(nanoseconds _: UInt64) async throws {
        advanceElapsed()
    }

    private func advanceElapsed() {
        lock.lock()
        elapsed &+= elapsedPerSleep
        lock.unlock()
    }
}

private actor DartProcessControllerStub: ProcessControlling {
    private var identities: [Int32: ProcessIdentity]
    private let submission: ProcessTerminationSubmission

    init(identities: [Int32: ProcessIdentity], submission: ProcessTerminationSubmission = .accepted) {
        self.identities = identities
        self.submission = submission
    }

    func identity(for pid: Int32) async -> ProcessIdentityLookup {
        guard let identity = identities[pid] else {
            return .unavailable(code: ESRCH)
        }
        return .found(identity)
    }

    func submitTermination(expectedIdentity _: ProcessIdentity) async -> ProcessTerminationSubmission {
        submission
    }
}

private actor DartCommandRunnerStub: ProcessCommandRunning {
    private var outputs: [String: [ProcessSubprocessOutput]]

    init(outputs: [String: [ProcessSubprocessOutput]]) {
        self.outputs = outputs
    }

    func run(_ path: String, arguments _: [String], timeout _: TimeInterval) async -> ProcessSubprocessOutput {
        guard var queued = outputs[path], !queued.isEmpty else {
            return ProcessSubprocessOutput(stdout: "", stderr: "missing stub", status: -1, timedOut: false)
        }
        let first = queued.removeFirst()
        outputs[path] = queued
        return first
    }
}
