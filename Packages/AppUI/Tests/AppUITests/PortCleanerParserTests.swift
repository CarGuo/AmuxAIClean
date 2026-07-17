import Darwin
import XCTest
@testable import AppUI

final class PortCleanerParserTests: XCTestCase {
    func test_boundedProcessTimeoutConversionHandlesEveryDoubleClassWithoutTrap() {
        XCTAssertEqual(PortCleanerBoundedProcessExecutor.normalizedTimeoutNanoseconds(.nan), 0)
        XCTAssertEqual(PortCleanerBoundedProcessExecutor.normalizedTimeoutNanoseconds(-1), 0)
        XCTAssertEqual(PortCleanerBoundedProcessExecutor.normalizedTimeoutNanoseconds(0), 0)
        XCTAssertEqual(
            PortCleanerBoundedProcessExecutor.normalizedTimeoutNanoseconds(0.25),
            250_000_000
        )
        XCTAssertEqual(
            PortCleanerBoundedProcessExecutor.normalizedTimeoutNanoseconds(.infinity),
            .max
        )
    }
    private func identity(
        pid: Int32,
        path: String,
        uid: UInt32 = UInt32(getuid()),
        startTime: UInt64 = 100
    ) -> PortCleanerProcessIdentity {
        PortCleanerProcessIdentity(
            pid: pid,
            uid: uid,
            executablePath: path,
            startTimeSeconds: startTime,
            startTimeMicroseconds: 7
        )
    }

    func test_parseLsof_监听TCP和UDP都能解析() {
        let sample = """
        p123
        cnode
        Lguoshuyu
        PTCP
        TST=LISTEN
        n*:3000
        PUDP
        n127.0.0.1:5353
        p456
        cPostgres
        Lpostgres
        PTCP
        TST=LISTEN
        n127.0.0.1:5432
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.localPort).sorted(), [3000, 5353, 5432])
        XCTAssertTrue(entries.contains { $0.processName == "node" && $0.proto == .tcp && $0.localAddress == "*" })
        XCTAssertTrue(entries.contains { $0.processName == "node" && $0.proto == .udp && $0.localAddress == "127.0.0.1" })
        XCTAssertTrue(entries.contains { $0.processName == "Postgres" && $0.pid == 456 && $0.user == "postgres" })
    }

    func test_parseLsof_IPV6和远端地址都能解析() {
        let sample = """
        p789
        cExample
        Ltester
        PTCP
        TST=ESTABLISHED
        n[::1]:8080->[::1]:50123
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].localAddress, "::1")
        XCTAssertEqual(entries[0].localPort, 8080)
        XCTAssertEqual(entries[0].remoteAddress, "::1")
        XCTAssertEqual(entries[0].remotePort, 50123)
        XCTAssertEqual(entries[0].state, "ESTABLISHED")
    }

    func test_parseLsof_macOS常见字段顺序也能保留状态并去重() {
        let sample = """
        p1109
        cControlCenter
        Lguoshuyu
        f10
        PTCP
        n*:7000
        TST=LISTEN
        f11
        PTCP
        n*:7000
        TST=LISTEN
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].localPort, 7000)
        XCTAssertEqual(entries[0].state, "LISTEN")
        XCTAssertEqual(entries[0].processName, "ControlCenter")
    }

    func test_parseHostPort_非法地址返回nil() {
        XCTAssertNil(PortCleanerParser.parseHostPort("no-port"))
        XCTAssertNil(PortCleanerParser.parseHostPort("[::1]8080"))
        XCTAssertNil(PortCleanerParser.parseHostPort("localhost:abc"))
    }

    func test_groups_同进程聚合并按端口数量排序() {
        let entries = [
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3000, pid: 1, processName: "node", processPath: "/usr/local/bin/node", user: "me"),
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3001, pid: 1, processName: "node", processPath: "/usr/local/bin/node", user: "me"),
            PortCleanerEntry(proto: .tcp, localAddress: "127.0.0.1", localPort: 5432, pid: 2, processName: "postgres", processPath: "/opt/postgres", user: "me")
        ]

        let groups = PortCleanerGroup.groups(from: entries)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "node")
        XCTAssertEqual(groups[0].portCount, 2)
        XCTAssertEqual(groups[0].pids, [1])
    }

    func test_terminationProtection_系统和root进程不可请求结束() {
        let apple = PortCleanerEntry(
            proto: .tcp,
            localAddress: "*",
            localPort: 5000,
            pid: 1109,
            processName: "ControlCenter",
            processPath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            user: "guoshuyu",
            processIdentity: identity(
                pid: 1109,
                path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
            )
        )
        let rootDaemon = PortCleanerEntry(
            proto: .tcp,
            localAddress: "*",
            localPort: 22,
            pid: 99,
            processName: "sshd",
            processPath: "/usr/sbin/sshd",
            user: "root",
            processIdentity: identity(pid: 99, path: "/usr/sbin/sshd", uid: 0)
        )
        let devServer = PortCleanerEntry(
            proto: .tcp,
            localAddress: "127.0.0.1",
            localPort: 3000,
            pid: 12345,
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            user: "guoshuyu",
            processIdentity: identity(pid: 12345, path: "/opt/homebrew/bin/node")
        )

        XCTAssertEqual(apple.terminationProtection, .systemProcess)
        XCTAssertFalse(apple.canRequestTermination)
        XCTAssertEqual(rootDaemon.terminationProtection, .privilegedUser)
        XCTAssertFalse(rootDaemon.canRequestTermination)
        XCTAssertNil(devServer.terminationProtection)
        XCTAssertTrue(devServer.canRequestTermination)
    }

    func test_groups_terminablePids只包含可安全请求结束的进程() {
        let entries = [
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3000, pid: 1, processName: "launchd", processPath: "/sbin/launchd", user: "root"),
            PortCleanerEntry(
                proto: .tcp,
                localAddress: "127.0.0.1",
                localPort: 3001,
                pid: 42,
                processName: "node",
                processPath: "/opt/homebrew/bin/node",
                user: "me",
                processIdentity: identity(pid: 42, path: "/opt/homebrew/bin/node")
            )
        ]

        let group = PortCleanerGroup(
            id: "mixed",
            title: "mixed",
            path: nil,
            user: nil,
            entries: entries
        )

        XCTAssertEqual(group.terminablePids, [42])
    }

    func test_terminationProtection_缺少内核身份时即使路径看似普通也不可结束() {
        let entry = PortCleanerEntry(
            proto: .tcp,
            localAddress: "127.0.0.1",
            localPort: 8080,
            pid: 88,
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            user: "me"
        )

        XCTAssertEqual(entry.terminationProtection, .identityUnavailable)
        XCTAssertFalse(entry.canRequestTermination)
    }

    func test_boundedExecutor_同时排空大stdout和stderr不会Pipe死锁() {
        let result = PortCleanerBoundedProcessExecutor.run(
            "/bin/sh",
            arguments: [
                "-c",
                "i=0; while [ \"$i\" -lt 12000 ]; do echo stdout-line; echo stderr-line >&2; i=$((i+1)); done"
            ],
            timeout: 4
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(result.stdout.utf8.count, 100_000)
        XCTAssertGreaterThan(result.stderr.utf8.count, 100_000)
    }

    func test_boundedExecutor_超时后TERM再KILL并在有界时间返回() {
        let start = Date()
        let result = PortCleanerBoundedProcessExecutor.run(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 0.05,
            terminationGrace: 0.05,
            killGrace: 1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func test_boundedExecutor_输出达到上限时返回typed截断状态() {
        let result = PortCleanerBoundedProcessExecutor.run(
            "/bin/sh",
            arguments: ["-c", "printf 123456789; printf err >&2"],
            timeout: 2,
            maximumOutputBytes: 4
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "1234")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.truncatedStreams, [.stdout])
        XCTAssertFalse(result.isCompleteSuccess,
                       "a capped stdout prefix must never masquerade as a complete snapshot")
    }

    func test_kill_执行前发现PID身份变化则拒绝发送信号() async {
        let frozen = identity(pid: 9001, path: "/opt/homebrew/bin/node", startTime: 10)
        let controller = PortCleanerProcessControllerStub(
            lookups: [:],
            submission: .identityChanged
        )
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 1_000_000, pollIntervalNanoseconds: 100_000)
        )

        let results = await scanner.kill(identities: [frozen])

        XCTAssertEqual(results.map(\.disposition), [.identityChanged])
        let submitted = await controller.submittedPIDs()
        XCTAssertEqual(submitted, [])
        let standaloneLookups = await controller.identityLookupCount()
        XCTAssertEqual(standaloneLookups, 0, "Scanner must not split revalidation and SIGTERM into two async calls")
    }

    func test_kill_执行层再次应用系统保护且不信任调用方() async {
        let protected = identity(pid: 9004, path: "/usr/bin/example")
        let controller = PortCleanerProcessControllerStub(
            lookups: [:],
            submission: .processBecameProtected
        )
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 1_000_000, pollIntervalNanoseconds: 100_000)
        )

        let results = await scanner.kill(identities: [protected])

        XCTAssertEqual(results.map(\.disposition), [.processBecameProtected])
        let submitted = await controller.submittedPIDs()
        XCTAssertEqual(submitted, [])
    }

    func test_DarwinController_可读取当前进程的稳定内核身份() async {
        let lookup = await DarwinPortCleanerProcessController().identity(for: getpid())

        guard case .found(let current) = lookup else {
            return XCTFail("Expected the test process identity, got \(lookup)")
        }
        XCTAssertEqual(current.pid, getpid())
        XCTAssertEqual(current.uid, UInt32(getuid()))
        XCTAssertFalse(current.executablePath.isEmpty)
        XCTAssertGreaterThan(current.startTimeSeconds, 0)
    }

    func test_killResult_提交和确认退出使用不同双语文案() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")

        XCTAssertEqual(
            PortCleanerKillDisposition.terminated.message(locale: chinese),
            "已确认进程退出"
        )
        XCTAssertEqual(
            PortCleanerKillDisposition.terminationRequested.message(locale: chinese),
            "已发送结束请求，尚未确认退出"
        )
        XCTAssertNotEqual(
            PortCleanerKillDisposition.identityChanged.message(locale: english),
            PortCleanerKillDisposition.identityChanged.message(locale: chinese)
        )
    }

    func test_kill_SIGTERM接受且身份消失后才确认成功() async {
        let frozen = identity(pid: 9002, path: "/opt/homebrew/bin/node")
        let controller = PortCleanerProcessControllerStub(
            lookups: [9002: [.notRunning]],
            submission: .accepted
        )
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 20_000_000, pollIntervalNanoseconds: 100_000)
        )

        let results = await scanner.kill(identities: [frozen])

        XCTAssertEqual(results.map(\.disposition), [.terminated])
        XCTAssertTrue(results[0].success)
        XCTAssertFalse(results[0].requestPending)
    }

    func test_kill_SIGTERM接受但身份仍存在时只报告请求待确认() async {
        let frozen = identity(pid: 9003, path: "/opt/homebrew/bin/node")
        let controller = PortCleanerProcessControllerStub(
            lookups: [9003: [.found(frozen)]],
            submission: .accepted
        )
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 2_000_000, pollIntervalNanoseconds: 200_000)
        )

        let results = await scanner.kill(identities: [frozen])

        XCTAssertEqual(results.map(\.disposition), [.terminationRequested])
        XCTAssertFalse(results[0].success)
        XCTAssertTrue(results[0].requestPending)
    }

    func test_kill_超过单轮安全上限的目标返回明确未提交结果() async {
        let identities = (0..<129).map { offset in
            identity(
                pid: Int32(10_000 + offset),
                path: "/opt/homebrew/bin/node",
                startTime: UInt64(offset + 1)
            )
        }
        let controller = PortCleanerProcessControllerStub(
            lookups: [:],
            submission: .identityChanged
        )
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(
                maximumWaitNanoseconds: 1_000_000,
                pollIntervalNanoseconds: 100_000
            )
        )

        let results = await scanner.kill(identities: identities)

        XCTAssertEqual(results.count, identities.count, "Confirmed targets must never be silently truncated")
        XCTAssertEqual(results.prefix(128).map(\.disposition), Array(repeating: .identityChanged, count: 128))
        XCTAssertEqual(results.last?.disposition, .notSubmittedBatchLimit)
        XCTAssertTrue(results.last?.notSubmitted == true)
    }

    func test_listPorts_identity前后变化时拒绝把旧端口绑定给复用PID() async {
        let first = identity(pid: 7001, path: "/opt/homebrew/bin/node", startTime: 10)
        // 即使复用后的进程使用同一路径，启动时间变化也必须整项丢弃。
        let reused = identity(pid: 7001, path: "/opt/homebrew/bin/node", startTime: 11)
        let controller = PortCleanerProcessControllerStub(
            lookups: [7001: [.found(first), .found(reused)]],
            submission: .accepted
        )
        let runner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [lsofOutput(pid: 7001), lsofOutput(pid: 7001)]
        ])
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 1_000_000, pollIntervalNanoseconds: 100_000),
            commandRunner: runner
        )

        let entries = successEntries(await scanner.listPorts())

        XCTAssertEqual(entries, [])
        let lsofCalls = await runner.callCount(for: "/usr/sbin/lsof")
        XCTAssertEqual(lsofCalls, 2)
    }

    func test_listPorts_lsof输出截断时拒绝解析部分快照() async {
        let controller = PortCleanerProcessControllerStub(
            lookups: [:],
            submission: .accepted
        )
        let runner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [PortCleanerSubprocessOutput(
                stdout: lsofOutput(pid: 7010).stdout,
                stderr: "",
                status: 0,
                timedOut: false,
                truncatedStreams: [.stdout]
            )]
        ])
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(
                maximumWaitNanoseconds: 1_000_000,
                pollIntervalNanoseconds: 100_000
            ),
            commandRunner: runner
        )

        let outcome = await scanner.listPorts()

        guard case .failure(.outputTruncated(command: .lsof)) = outcome else {
            return XCTFail("Expected typed truncated lsof failure, got \(outcome)")
        }
        let lookups = await controller.identityLookupCount()
        XCTAssertEqual(lookups, 0,
                       "truncated discovery must be rejected before freezing any process identity")
    }

    func test_listPorts_仅发布第二轮端口且身份夹验一致的快照() async {
        let stable = identity(pid: 7002, path: "/opt/homebrew/bin/node", startTime: 20)
        let controller = PortCleanerProcessControllerStub(
            lookups: [7002: [.found(stable), .found(stable)]],
            submission: .accepted
        )
        let runner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [
                lsofOutput(pid: 7002, port: 3000),
                lsofOutput(pid: 7002, port: 3001)
            ],
            "/bin/ps": [PortCleanerSubprocessOutput(
                stdout: "7002 tester /opt/homebrew/bin/node\n",
                stderr: "",
                status: 0,
                timedOut: false
            )]
        ])
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(maximumWaitNanoseconds: 1_000_000, pollIntervalNanoseconds: 100_000),
            commandRunner: runner
        )

        let entries = successEntries(await scanner.listPorts())

        XCTAssertEqual(entries.map(\.localPort), [3001])
        XCTAssertEqual(entries.first?.processIdentity, stable)
        XCTAssertEqual(entries.first?.processPath, stable.executablePath)
    }

    func test_listPorts_ps输出截断时不使用部分metadata() async {
        let stable = identity(pid: 7003, path: "/opt/homebrew/bin/node", startTime: 30)
        let controller = PortCleanerProcessControllerStub(
            lookups: [7003: [.found(stable), .found(stable)]],
            submission: .accepted
        )
        let lsofWithoutUser = PortCleanerSubprocessOutput(
            stdout: """
            p7003
            cnode
            PTCP
            TST=LISTEN
            n127.0.0.1:3003
            """,
            stderr: "",
            status: 0,
            timedOut: false
        )
        let runner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [lsofWithoutUser, lsofWithoutUser],
            "/bin/ps": [PortCleanerSubprocessOutput(
                stdout: "7003 injected /wrong/path\n",
                stderr: "",
                status: 0,
                timedOut: false,
                truncatedStreams: [.stdout]
            )]
        ])
        let scanner = PortCleanerScanner(
            processController: controller,
            verificationPolicy: .init(
                maximumWaitNanoseconds: 1_000_000,
                pollIntervalNanoseconds: 100_000
            ),
            commandRunner: runner
        )

        let outcome = await scanner.listPorts()

        guard case .failure(.outputTruncated(command: .ps)) = outcome else {
            return XCTFail("Expected typed truncated ps failure, got \(outcome)")
        }
    }

    func test_listPorts_完整空lsof是可信success而非failure() async {
        let scanner = PortCleanerScanner(
            processController: PortCleanerProcessControllerStub(
                lookups: [:],
                submission: .accepted
            ),
            verificationPolicy: .init(
                maximumWaitNanoseconds: 1_000_000,
                pollIntervalNanoseconds: 100_000
            ),
            commandRunner: PortCleanerCommandRunnerStub(outputs: [
                "/usr/sbin/lsof": [PortCleanerSubprocessOutput(
                    stdout: "",
                    stderr: "",
                    status: 0,
                    timedOut: false
                )]
            ])
        )

        let entries = successEntries(await scanner.listPorts())

        XCTAssertTrue(entries.isEmpty)
    }

    func test_listPorts_lsof命令失败与超时返回typedFailure且不泄露stderr() async {
        let failedRunner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [PortCleanerSubprocessOutput(
                stdout: "partial",
                stderr: "sensitive raw diagnostics",
                status: 7,
                timedOut: false
            )]
        ])
        let timedOutRunner = PortCleanerCommandRunnerStub(outputs: [
            "/usr/sbin/lsof": [PortCleanerSubprocessOutput(
                stdout: "partial",
                stderr: "another raw diagnostic",
                status: -2,
                timedOut: true
            )]
        ])
        let controller = PortCleanerProcessControllerStub(lookups: [:], submission: .accepted)
        let policy = PortCleanerTerminationVerificationPolicy(
            maximumWaitNanoseconds: 1_000_000,
            pollIntervalNanoseconds: 100_000
        )

        let failed = await PortCleanerScanner(
            processController: controller,
            verificationPolicy: policy,
            commandRunner: failedRunner
        ).listPorts()
        let timedOut = await PortCleanerScanner(
            processController: controller,
            verificationPolicy: policy,
            commandRunner: timedOutRunner
        ).listPorts()

        guard case .failure(.commandFailed(command: .lsof)) = failed else {
            return XCTFail("Expected typed command failure, got \(failed)")
        }
        guard case .failure(.timedOut(command: .lsof)) = timedOut else {
            return XCTFail("Expected typed timeout, got \(timedOut)")
        }
        XCTAssertFalse(
            PortCleanerScanFailure.commandFailed(command: .lsof)
                .message(locale: Locale(identifier: "en"))
                .contains("sensitive")
        )
    }

    private func successEntries(
        _ outcome: PortCleanerScanOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> [PortCleanerEntry] {
        guard case .success(let entries) = outcome else {
            XCTFail("Expected successful port snapshot, got \(outcome)", file: file, line: line)
            return []
        }
        return entries
    }

    private func lsofOutput(pid: Int32, port: Int = 3000) -> PortCleanerSubprocessOutput {
        PortCleanerSubprocessOutput(
            stdout: """
            p\(pid)
            cnode
            Ltester
            PTCP
            TST=LISTEN
            n127.0.0.1:\(port)
            """,
            stderr: "",
            status: 0,
            timedOut: false
        )
    }
}

private actor PortCleanerProcessControllerStub: PortCleanerProcessControlling {
    private var lookups: [Int32: [PortCleanerProcessIdentityLookup]]
    private let submission: PortCleanerTerminationSubmission
    private var submissions: [Int32] = []
    private var lookupCalls = 0

    init(
        lookups: [Int32: [PortCleanerProcessIdentityLookup]],
        submission: PortCleanerTerminationSubmission
    ) {
        self.lookups = lookups
        self.submission = submission
    }

    func identity(for pid: Int32) async -> PortCleanerProcessIdentityLookup {
        lookupCalls += 1
        guard var values = lookups[pid], let first = values.first else {
            return .unavailable(code: ESRCH)
        }
        if values.count > 1 {
            values.removeFirst()
            lookups[pid] = values
        }
        return first
    }

    func submitTermination(
        expectedIdentity: PortCleanerProcessIdentity
    ) async -> PortCleanerTerminationSubmission {
        if submission == .accepted {
            submissions.append(expectedIdentity.pid)
        }
        return submission
    }

    func submittedPIDs() -> [Int32] {
        submissions
    }

    func identityLookupCount() -> Int {
        lookupCalls
    }
}

private actor PortCleanerCommandRunnerStub: PortCleanerCommandRunning {
    private var outputs: [String: [PortCleanerSubprocessOutput]]
    private var calls: [String: Int] = [:]

    init(outputs: [String: [PortCleanerSubprocessOutput]]) {
        self.outputs = outputs
    }

    func run(
        _ path: String,
        arguments _: [String],
        timeout _: TimeInterval
    ) async -> PortCleanerSubprocessOutput {
        calls[path, default: 0] += 1
        guard var queued = outputs[path], !queued.isEmpty else {
            return PortCleanerSubprocessOutput(stdout: "", stderr: "missing stub", status: -1, timedOut: false)
        }
        let first = queued.removeFirst()
        outputs[path] = queued
        return first
    }

    func callCount(for path: String) -> Int {
        calls[path, default: 0]
    }
}
