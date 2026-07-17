import XCTest
import Darwin
@testable import ScanKit

/// v1.7 M1 PR-2：SubprocessExecutor 的契约钉死测试。
///
/// 这套测试不是补"代码逻辑对不对"，而是补"未来谁改了某一行让 allowlist 形同虚设"
/// 这种回归——所以每个用例都对应一个 PITFALL：
///
/// 1. **allowlist 是唯一闸门**：空 list = 全部拒绝；不匹配 executable = 拒绝；
///    args 前缀不等 = 拒绝；前缀匹配（即便 args 更长）= 放行。
/// 2. **dryRun 不能绕过 allowlist**：必须先校验再 dryRun。
/// 3. **实际执行路径的错误返回契约**：launch 失败 = -1，超时 = -2，与
///    MaintenanceCommandResult 完全同构。
///
/// 设计原则：
/// - 不依赖 Xcode：所有真执行用例都走 /bin/echo、/bin/sleep、/usr/bin/notexist，
///   xcrun/simctl 仅用于 allowlist 逻辑校验（throw / dryRun 阶段），不真起。
/// - /bin/echo、/bin/sleep 不在默认 allowlist，必须通过 init(allowlist:) 显式注入。
final class SubprocessExecutorTests: XCTestCase {

    // MARK: - 1. allowlist 闸门：空 list = 全部拒绝

    /// PITFALL：未来若有人把默认 allowlist 误改为 `[]`（或被某个 PR 注掉条目），
    /// 必须立即红——否则等于把执行器变成"任意命令通道"。
    func test_allowlist_为空_任何命令都拒绝() {
        let exec = SubprocessExecutor(allowlist: [], timeout: 1, dryRun: false)
        XCTAssertThrowsError(try exec.run(executable: "/usr/bin/xcrun",
                                          args: ["simctl", "list", "devices", "--json"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed(let e, let a) = err else {
                return XCTFail("空 allowlist 必须 throw notAllowed，得到：\(err)")
            }
            XCTAssertEqual(e, "/usr/bin/xcrun")
            XCTAssertEqual(a, ["simctl", "list", "devices", "--json"])
        }
    }

    // MARK: - 2. allowlist 闸门：executable 不匹配 = 拒绝

    /// PITFALL：argsPrefix 即便完全为空，executable 路径不等仍必须拒绝；
    /// 避免未来谁误写成 "endsWith" / "contains" 匹配。
    func test_executable_不匹配_拒绝执行() {
        let exec = SubprocessExecutor() // 默认 allowlist 只放 /usr/bin/xcrun
        XCTAssertThrowsError(try exec.run(executable: "/bin/ls", args: ["-la"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed = err else {
                return XCTFail("/bin/ls 不在默认 allowlist，必须 throw notAllowed，得到：\(err)")
            }
        }
    }

    // MARK: - 3. allowlist 闸门：executable 匹配但 args 前缀不匹配 = 拒绝

    /// PITFALL：默认 allowlist 里 `["simctl","list","devices","--json"]` 与
    /// `["simctl","list","apps"]` 共享前两个 token；如果有人把匹配写成
    /// "args.contains(prefix.first)" 或前缀长度比较错误，apps 会被 devices 条目放过。
    /// 该测试钉死前缀必须**逐元素等长比较**。
    func test_executable_匹配但_args_前缀不匹配_拒绝() {
        let exec = SubprocessExecutor()
        XCTAssertThrowsError(try exec.run(executable: "/usr/bin/xcrun",
                                          args: ["simctl", "list", "apps"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed = err else {
                return XCTFail("simctl list apps 不应被 simctl list devices 条目放过，得到：\(err)")
            }
        }
    }

    // MARK: - 4. allowlist 闸门：args 前缀完全相等 = 允许

    /// PITFALL：与上一个用例对偶——完全相等必须放行，配合 dryRun 让用例不依赖 Xcode。
    /// 若失败说明长度等于 prefix 的边界情况被误拒。
    func test_executable_匹配且_args_前缀完全相等_允许() throws {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        let r = try exec.run(executable: "/usr/bin/xcrun",
                             args: ["simctl", "list", "devices", "--json"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.hasPrefix("<dryRun> "), "dryRun 输出必须以 `<dryRun> ` 开头")
    }

    func test_runtimeListJSON_只读命令命中默认allowlist() throws {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        let result = try exec.run(executable: "/usr/bin/xcrun",
                                  args: ["simctl", "runtime", "list", "-j"])
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.output.contains("simctl runtime list -j"))
    }

    // MARK: - 5. allowlist 闸门：args 长于前缀 = 允许

    /// PITFALL：`simctl delete <UUID>` 必须被 `["simctl","delete"]` 这种短前缀放过；
    /// 若有人误写成 "args == prefix" 全等比较，此处会红。
    func test_executable_匹配且_args_长于前缀_允许() throws {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        let uuid = "11111111-2222-3333-4444-555555555555"
        let r = try exec.run(executable: "/usr/bin/xcrun",
                             args: ["simctl", "delete", uuid])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.contains("simctl delete \(uuid)"))
    }

    func test_destructive_simctl_delete_tail_必须是真UUID() {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        XCTAssertThrowsError(try exec.run(executable: "/usr/bin/xcrun",
                                          args: ["simctl", "delete", "all"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed = err else {
                return XCTFail("simctl delete all 必须被 tail policy 拒绝，得到：\(err)")
            }
        }
    }

    func test_destructive_simctl_delete_tail_拒绝额外参数() {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        XCTAssertThrowsError(try exec.run(executable: "/usr/bin/xcrun",
                                          args: ["simctl", "delete", "11111111-2222-3333-4444-555555555555", "--extra"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed = err else {
                return XCTFail("simctl delete <UUID> --extra 必须被 tail policy 拒绝，得到：\(err)")
            }
        }
    }

    func test_destructive_simctl_runtime_delete_tail_必须是runtimeUUID() throws {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        let uuid = "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7"
        let result = try exec.run(executable: "/usr/bin/xcrun",
                                  args: ["simctl", "runtime", "delete", uuid])
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.output.contains("simctl runtime delete \(uuid)"))
    }

    func test_destructive_simctl_runtime_delete_拒绝semanticIdentifier() {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        XCTAssertThrowsError(try exec.run(
            executable: "/usr/bin/xcrun",
            args: ["simctl", "runtime", "delete", "com.apple.CoreSimulator.SimRuntime.iOS-18-0"]
        )) { error in
            guard case SubprocessExecutor.SubprocessError.notAllowed = error else {
                return XCTFail("semantic runtime identifier 必须被 tail policy 拒绝，得到：\(error)")
            }
        }
    }

    // MARK: - 6. dryRun 命中 allowlist：返回 exitCode 0 + `<dryRun> ` 前缀

    /// PITFALL：dryRun 用于"用户预览"+"测试不真起进程"，输出必须以固定 `<dryRun> ` 前缀，
    /// 调用方（包括 UI 预览面板）会按该前缀识别。若前缀被改名（如 "[dryRun]"），
    /// 所有依赖该约定的上层代码会静默失效——此处用 hasPrefix 钉死。
    func test_dryRun_命中allowlist_不真起进程_返回exitCode_0_含dryRun前缀() throws {
        let exec = SubprocessExecutor(timeout: 1, dryRun: true)
        let runtimeID = "5B8AD6C2-263A-40BB-80DB-B2751E2ACAD7"
        let r = try exec.run(executable: "/usr/bin/xcrun",
                             args: ["simctl", "runtime", "delete", runtimeID])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.hasPrefix("<dryRun> /usr/bin/xcrun "),
                      "dryRun 必须输出完整 `<dryRun> <executable> <args>`，得到：\(r.output)")
        XCTAssertTrue(r.output.contains("simctl runtime delete \(runtimeID)"))
    }

    // MARK: - 7. dryRun 未命中 allowlist：仍 throw notAllowed（先校验再 dryRun）

    /// PITFALL：dryRun 绝不能成为绕开 allowlist 的后门。
    /// 若未来谁把 dryRun 分支移到 allowlist 之前（"反正不真跑，先放行"），
    /// 等于打开了"任意路径预览泄漏"通道——此处用例必须保持先 throw。
    func test_dryRun_未命中allowlist_仍然抛notAllowed_先校验再dryRun() {
        let exec = SubprocessExecutor(allowlist: [], timeout: 1, dryRun: true)
        XCTAssertThrowsError(try exec.run(executable: "/usr/bin/xcrun",
                                          args: ["simctl", "list", "devices", "--json"])) { err in
            guard case SubprocessExecutor.SubprocessError.notAllowed = err else {
                return XCTFail("dryRun 不应绕过 allowlist，必须 throw notAllowed，得到：\(err)")
            }
        }
    }

    // MARK: - 8. 实际执行 /bin/echo hello：成功 + stdout 解析

    /// PITFALL：验证真起进程路径——allowlist 注入、Pipe 合并 stdout、terminationStatus 透传。
    /// 用 /bin/echo（不依赖 Xcode、CI 上必有）+ 自定义 allowlist 注入。
    func test_实际执行_echo_hello_成功() throws {
        let echo = SubprocessExecutor.AllowEntry(executable: "/bin/echo", argsPrefix: ["hello"])
        let exec = SubprocessExecutor(allowlist: [echo], timeout: 5, dryRun: false)
        let r = try exec.run(executable: "/bin/echo", args: ["hello", "world"])
        XCTAssertEqual(r.exitCode, 0, "echo 成功必须 exit 0")
        XCTAssertTrue(r.isSuccess)
        XCTAssertTrue(r.output.contains("hello world"),
                      "stdout 必须经 Pipe 解析为字符串，得到：\(r.output)")
    }

    /// v2026.07.15：只读 discovery 默认必须保持有界 timeout；这是扫描可重试的前提。
    func test_默认executor_保留查询timeout策略() {
        XCTAssertEqual(
            SubprocessExecutor(dryRun: true).terminalWaitPolicy,
            .timeout(5)
        )
    }

    /// managed destructive command 当前项必须等待真实终态，不能复用查询 timeout 后强杀。
    func test_waitUntilExit策略_显式可选且自然返回() throws {
        let echo = SubprocessExecutor.AllowEntry(executable: "/bin/echo", argsPrefix: ["managed"])
        let exec = SubprocessExecutor(
            allowlist: [echo],
            terminalWaitPolicy: .waitUntilExit,
            dryRun: false
        )
        XCTAssertEqual(exec.terminalWaitPolicy, .waitUntilExit)
        let result = try exec.run(executable: "/bin/echo", args: ["managed", "done"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("managed done"))
    }

    /// **v2026.07.16 回归合同**：stall 是观察状态，不是破坏性 timeout。即便观察窗口
    /// 先耗尽，/bin/sleep 仍应自然 exit 0；若实现偷偷复用 timeout 的 TERM/KILL，此测试会红。
    func test_managed观察流_区分提交运行停滞与真实终态_且不强杀进程() async throws {
        let sleep = SubprocessExecutor.AllowEntry(executable: "/bin/sleep", argsPrefix: ["0.2"])
        let exec = SubprocessExecutor(
            allowlist: [sleep],
            terminalWaitPolicy: .waitUntilExit,
            dryRun: false
        )
        let startedAt = Date()
        let updates = try exec.observeManagedExecution(
            executable: "/bin/sleep",
            args: ["0.2"],
            stallAfter: 0.03
        )

        var collected: [SubprocessExecutor.ManagedExecutionUpdate] = []
        for await update in updates {
            collected.append(update)
        }

        guard collected.count >= 4 else {
            return XCTFail("managed lifecycle 缺少事件：\(collected)")
        }
        guard case .submitted(let pid) = collected[0] else {
            return XCTFail("第一条事件必须证明 Process.run 已提交")
        }
        XCTAssertNotNil(pid)
        guard case .running = collected[1] else {
            return XCTFail("第二条事件必须是 running")
        }
        guard case .stalled(_, let elapsed) = collected[2] else {
            return XCTFail("观察窗口耗尽必须先发布 stalled，而不是终止进程")
        }
        XCTAssertEqual(elapsed, 0.03, accuracy: 0.001)
        guard case .confirmedTerminal(let result) = collected.last else {
            return XCTFail("后台自然结束后必须发布 confirmed terminal")
        }
        XCTAssertEqual(result.exitCode, 0, "stall watchdog 绝不能 TERM/KILL managed transaction")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.15)
    }

    func test_managed观察流_仍在创建流前同步执行allowlist和UUID校验() {
        let exec = SubprocessExecutor(
            terminalWaitPolicy: .waitUntilExit,
            dryRun: true
        )
        XCTAssertThrowsError(try exec.observeManagedExecution(
            executable: "/usr/bin/xcrun",
            args: ["simctl", "runtime", "delete", "not-a-uuid"],
            stallAfter: 1
        )) { error in
            guard case SubprocessExecutor.SubprocessError.notAllowed = error else {
                return XCTFail("managed observer 不得绕过 destructive tail policy: \(error)")
            }
        }
    }

    func test_managed执行前安全闸拒绝时_没有PID也没有伪终态() async throws {
        let exec = SubprocessExecutor(
            terminalWaitPolicy: .waitUntilExit,
            dryRun: true
        )
        let updates = try exec.observeManagedExecution(
            executable: "/usr/bin/xcrun",
            args: ["simctl", "runtime", "delete", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],
            stallAfter: 1,
            preSubmissionGuard: { .persistentPendingOperation }
        )
        var collected: [SubprocessExecutor.ManagedExecutionUpdate] = []
        for await update in updates { collected.append(update) }
        XCTAssertEqual(collected, [.submissionRejected(.persistentPendingOperation)])
    }

    /// **v2026.07.16 阶段屏障回归**：持久 submitted 转换失败时必须停在
    /// `Process.run()` 之前，不能发布 submitted/running，更不能伪造 terminal。
    func test_managed持久提交屏障失败_明确零提交() async throws {
        let exec = SubprocessExecutor(
            terminalWaitPolicy: .waitUntilExit,
            dryRun: true
        )
        let order = ManagedSubmissionOrderRecorder()
        let updates = try exec.observeManagedExecution(
            executable: "/usr/bin/xcrun",
            args: ["simctl", "runtime", "delete", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"],
            stallAfter: 1,
            preSubmissionGuard: {
                order.append("guard")
                return .allow
            },
            preLaunchPersistenceBarrier: {
                order.append("persistence")
                return false
            }
        )
        var collected: [SubprocessExecutor.ManagedExecutionUpdate] = []
        for await update in updates { collected.append(update) }

        XCTAssertEqual(order.snapshot(), ["guard", "persistence"])
        XCTAssertEqual(collected, [.submissionRejected(.verificationUnavailable)])
    }

    func test_大量stdout持续排空但诊断保留有界() throws {
        let yes = SubprocessExecutor.AllowEntry(
            executable: "/usr/bin/yes",
            argsPrefix: ["bounded-output"]
        )
        let exec = SubprocessExecutor(allowlist: [yes], timeout: 0.05, dryRun: false)
        let result = try exec.run(executable: "/usr/bin/yes", args: ["bounded-output"])

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.output.contains("output truncated"))
        XCTAssertLessThanOrEqual(
            result.output.utf8.count,
            SubprocessExecutor.outputCaptureLimitPerStream + 512,
            "readability handler 必须持续排空超量输出，但内存诊断缓冲不能无界增长"
        )
    }

    /// **v2026.07.16 P0 回归**：simctl 的诊断通常写到 stderr。stderr handler 的锁
    /// 必须与 stdout 一样严格成对，否则首个诊断 chunk 就可能触发未持锁 unlock 崩溃。
    func test_真实stderr可排空并保留非零退出码() throws {
        let script = "printf 'simctl diagnostic\\n' >&2; exit 7"
        let shell = SubprocessExecutor.AllowEntry(
            executable: "/bin/sh",
            argsPrefix: ["-c", script]
        )
        let exec = SubprocessExecutor(allowlist: [shell], timeout: 5, dryRun: false)
        let result = try exec.run(executable: "/bin/sh", args: ["-c", script])

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.output.contains("simctl diagnostic"))
    }

    /// stdout/stderr 分别由并发 writer 产生，钉死两个 readability handler 共享锁时
    /// 不得死锁、越界解锁或遗漏整条数据流。输出规模保持在各自 64 KiB 上限内。
    func test_并发stdout与stderr都能完整排空() throws {
        let script = """
        (i=0; while [ $i -lt 512 ]; do printf 'stdout-%04d\\n' "$i"; i=$((i+1)); done) &
        (i=0; while [ $i -lt 512 ]; do printf 'stderr-%04d\\n' "$i" >&2; i=$((i+1)); done) &
        wait
        """
        let shell = SubprocessExecutor.AllowEntry(
            executable: "/bin/sh",
            argsPrefix: ["-c", script]
        )
        let exec = SubprocessExecutor(allowlist: [shell], timeout: 5, dryRun: false)
        let result = try exec.run(executable: "/bin/sh", args: ["-c", script])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("stdout-0000"))
        XCTAssertTrue(result.output.contains("stdout-0511"))
        XCTAssertTrue(result.output.contains("stderr-0000"))
        XCTAssertTrue(result.output.contains("stderr-0511"))
        XCTAssertFalse(result.output.contains("output truncated"))
    }

    // MARK: - 9. 超时：sleep 30s + timeout 0.5s → terminate，exitCode = -2

    /// PITFALL：超时闸门是防"长任务卡死调用线程"的最后防线；
    /// 若有人把 terminate 改成 interrupt 而忘了改 exitCode 约定，
    /// 上层 -2 == 超时 的判断会失效。此处钉死 -2 + 输出含 "timeout"。
    func test_超时_sleep_30s_被terminate() throws {
        let sleepEntry = SubprocessExecutor.AllowEntry(executable: "/bin/sleep", argsPrefix: ["30"])
        let exec = SubprocessExecutor(allowlist: [sleepEntry], timeout: 0.5, dryRun: false)
        let start = Date()
        let r = try exec.run(executable: "/bin/sleep", args: ["30"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.exitCode, -2, "超时必须返回 -2，得到 \(r.exitCode)")
        XCTAssertTrue(r.output.contains("timeout"), "超时输出必须含 'timeout'：\(r.output)")
        XCTAssertLessThan(elapsed, 5,
                          "超时应在 ~0.5s 触发，不应等满 30s，实际耗时 \(elapsed)s")
    }

    /// SAFETY v2026.07.16：若首次 owned wait 已经 reap，PID 已可能被系统复用；状态机
    /// 必须直接返回终态，既不能 TERM，也不能 KILL。用注入 syscall 让该竞态确定可复现。
    func test_ownedWait_已reap后绝不对缓存PID发信号() {
        var signals: [Int32] = []
        var waiterCalled = false
        let terminal = OwnedChildProcessExecutor.resolveTimeout(
            pid: 42,
            initial: .reaped(status: 0),
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in
                waiterCalled = true
                return .notOwned
            },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .exited(status: 0))
        XCTAssertFalse(waiterCalled)
        XCTAssertTrue(signals.isEmpty, "reaped PID 不得收到任何后续信号")
    }

    func test_ownedWaitTimeoutConversionHandlesEveryDoubleClassWithoutTrap() {
        XCTAssertEqual(OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(.nan), 0)
        XCTAssertEqual(OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(-1), 0)
        XCTAssertEqual(OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(0), 0)
        XCTAssertEqual(OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(0.25), 250_000_000)
        XCTAssertEqual(OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(.infinity), .max)
        XCTAssertEqual(
            OwnedChildProcessExecutor.normalizedTimeoutNanoseconds(.greatestFiniteMagnitude),
            .max
        )
    }

    /// SAFETY v2026.07.17：取消请求若发生在 child 已 reap 之后，缓存 PID 已可能复用。
    /// 独立 cancellation 状态机必须与 timeout 一样直接返回真实 exit，绝不 signal。
    func test_ownedCancellation_已reap后绝不对缓存PID发信号() {
        var signals: [Int32] = []
        var waiterCalled = false
        let terminal = OwnedChildProcessExecutor.resolveCancellation(
            pid: 45,
            initial: .reaped(status: 0),
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in
                waiterCalled = true
                return .notOwned
            },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .exited(status: 0))
        XCTAssertFalse(waiterCalled)
        XCTAssertTrue(signals.isEmpty, "reaped PID 不得因取消收到任何信号")
    }

    /// 取消与 timeout 必须保留不同终态；TERM 后 ECHILD 也必须永久关闭 KILL 路径。
    func test_ownedCancellation_TERM后ECHILD_不再升级KILL() {
        var signals: [Int32] = []
        let terminal = OwnedChildProcessExecutor.resolveCancellation(
            pid: 46,
            initial: .running,
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in .notOwned },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .cancelled(sentSIGKILL: false, reapTransferred: false))
        XCTAssertEqual(signals, [SIGTERM], "首次 ECHILD 后不得继续 SIGKILL")
    }

    /// 若 child 忽略 TERM 且同步 KILL 宽限也未收敛，wait ownership 只能转移一次；
    /// 返回后任何路径都不得再对该 PID 发信号。
    func test_ownedCancellation_忽略TERM后升级KILL并转移唯一reap义务() {
        var waits: [OwnedChildProcessExecutor.WaitState] = [.running, .running]
        var signals: [Int32] = []
        let terminal = OwnedChildProcessExecutor.resolveCancellation(
            pid: 47,
            initial: .running,
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in waits.removeFirst() },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .cancelled(sentSIGKILL: true, reapTransferred: true))
        XCTAssertEqual(signals, [SIGTERM, SIGKILL])
        XCTAssertTrue(waits.isEmpty)
    }

    /// SAFETY v2026.07.16：`ECHILD` 代表唯一 owner 已丢失，后续即使宽限期结束也不能
    /// 猜测 PID 身份。该分支必须 fail closed，且永不 signal。
    func test_ownedWait_ECHILD后绝不对缓存PID发信号() {
        var signals: [Int32] = []
        let terminal = OwnedChildProcessExecutor.resolveTimeout(
            pid: 43,
            initial: .notOwned,
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in .running },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .notOwned)
        XCTAssertTrue(signals.isEmpty, "ECHILD 后必须永久关闭 signal 路径")
    }

    func test_ownedWait_TERM后ECHILD_不再升级KILL() {
        var signals: [Int32] = []
        let terminal = OwnedChildProcessExecutor.resolveTimeout(
            pid: 44,
            initial: .running,
            terminationGrace: 1,
            killGrace: 1,
            waiter: { _, _ in .notOwned },
            signaler: { _, signal in signals.append(signal) }
        )

        XCTAssertEqual(terminal, .timedOut(sentSIGKILL: false, reapTransferred: false))
        XCTAssertEqual(signals, [SIGTERM], "首次 ECHILD 后不得继续 SIGKILL")
    }

    /// 真子进程超时必须由同步 owner reap 完成；测试只运行 `/bin/sleep` fixture，既不
    /// 触发 simctl，也不执行任何用户数据操作。
    func test_ownedChild_真实超时后已收敛且无遗留wait义务() {
        let pidRecorder = OwnedChildPIDRecorder()
        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sleep",
            arguments: ["30"],
            timeout: 0.05,
            outputLimitPerStream: 1_024,
            onSpawn: { pidRecorder.store($0) }
        )

        guard case .timedOut = result.terminal else {
            return XCTFail("sleep fixture 应超时，得到 \(result.terminal)")
        }
        guard let pid = pidRecorder.value else {
            return XCTFail("spawn 后必须提供 owned PID")
        }
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "返回前 child 必须已 reap，不得遗留并发 waiter")
    }

    /// v2026.07.17：真实 cooperative cancellation 先由 WNOHANG 证明 child 仍 owned，
    /// 再 TERM -> reap；测试只操作 `/bin/sleep` fixture，不触碰任何用户数据。
    func test_ownedChild_真实取消后返回独立终态且无遗留wait义务() {
        let pidRecorder = OwnedChildPIDRecorder()
        let cancellation = OwnedCancellationCheckProbe(cancelAfterCheckCount: 2)
        let start = Date()
        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sleep",
            arguments: ["30"],
            timeout: nil,
            terminationGrace: 0.1,
            killGrace: 0.1,
            outputLimitPerStream: 1_024,
            onSpawn: { pidRecorder.store($0) },
            isCancelled: { cancellation.isCancelled() }
        )

        guard case .cancelled = result.terminal else {
            return XCTFail("sleep fixture 应被取消，得到 \(result.terminal)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard let pid = pidRecorder.value else {
            return XCTFail("spawn 后必须提供 owned PID")
        }
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "取消返回前 child 必须已 reap，不得遗留并发 waiter")
    }

    /// 调用在 spawn 前已经取消时，不应为了生成终态而启动任何命令。用不存在 executable
    /// 钉死顺序：若实现先 spawn，结果会错误变成 launchFailed。
    func test_ownedChild_spawn前已取消_不启动子进程() {
        let result = OwnedChildProcessExecutor.run(
            path: "/usr/bin/definitely-not-present",
            arguments: [],
            timeout: 5,
            outputLimitPerStream: 1_024,
            isCancelled: { true }
        )

        XCTAssertEqual(
            result.terminal,
            .cancelled(sentSIGKILL: false, reapTransferred: false)
        )
        XCTAssertEqual(result.output, "")
        XCTAssertTrue(result.readersReachedEOF)
    }

    /// stdout chunk 在 pipe reader queue 上按读取顺序发布；调用方不必等进程退出才看到
    /// 进度协议，同时最终 bounded capture 仍保持原有完整结果。
    func test_ownedChild_stdoutChunk按读取顺序流式发布() {
        let recorder = OwnedStdoutChunkRecorder()
        let script = "printf 'phase-1\\n'; /bin/sleep 0.05; printf 'phase-2\\n'"
        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sh",
            arguments: ["-c", script],
            timeout: 5,
            outputLimitPerStream: 1_024,
            onStdoutChunk: { recorder.append($0) }
        )

        XCTAssertEqual(result.terminal, .exited(status: 0))
        XCTAssertEqual(recorder.string, "phase-1\nphase-2\n")
        XCTAssertEqual(result.stdout, recorder.string)
        XCTAssertTrue(result.readersReachedEOF)
    }

    /// 流式进度与诊断 capture 的内存上限是两个正交合同：即使最终 capture 截断，
    /// reader 仍必须排空并把每个已读 stdout byte 交给 Sendable callback。
    func test_ownedChild_stdoutChunk不受诊断capture上限截断() {
        let recorder = OwnedStdoutChunkRecorder()
        let script = "i=0; while [ $i -lt 128 ]; do printf 'progress-%03d\\n' \"$i\"; i=$((i+1)); done"
        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sh",
            arguments: ["-c", script],
            timeout: 5,
            outputLimitPerStream: 32,
            onStdoutChunk: { recorder.append($0) }
        )

        XCTAssertEqual(result.terminal, .exited(status: 0))
        XCTAssertTrue(result.stdoutWasTruncated)
        XCTAssertTrue(recorder.string.hasPrefix("progress-000\n"))
        XCTAssertTrue(recorder.string.contains("progress-127\n"))
        XCTAssertGreaterThan(recorder.data.count, 32)
        XCTAssertTrue(result.readersReachedEOF)
    }

    /// SAFETY v2026.07.17：请求 FD 只通过显式 stdin 映射进入 child；父进程仍持有并负责
    /// 关闭原始只读 FD，executor 不改变唯一 waitpid owner 合同。
    func test_ownedChild_显式只读FD映射到stdin且不夺取父FD所有权() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnedInput-\(UUID().uuidString)")
        try Data("private-request\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = close(fd) }

        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sh",
            arguments: ["-c", "IFS= read -r value; printf '%s' \"$value\""],
            standardInputFD: fd,
            timeout: 5,
            outputLimitPerStream: 1_024
        )

        XCTAssertEqual(result.terminal, .exited(status: 0))
        XCTAssertEqual(result.stdout, "private-request")
        XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFL), 0, "原始 FD 仍由 caller 所有")
    }

    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` 必须关闭未列入 file actions 的 ambient descriptor，
    /// 即使父进程特意清除了该 descriptor 自身的 FD_CLOEXEC 位。
    func test_ownedChild_未声明的ambientFD不会继承() {
        let baseFD = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(baseFD, 0)
        guard baseFD >= 0 else { return }
        defer { _ = close(baseFD) }
        let ambientFD = fcntl(baseFD, F_DUPFD, 100)
        XCTAssertGreaterThanOrEqual(ambientFD, 100)
        guard ambientFD >= 100 else { return }
        defer { _ = close(ambientFD) }
        XCTAssertEqual(fcntl(ambientFD, F_SETFD, 0), 0)

        let probe = "if /bin/sh -c 'true <&\(ambientFD)' 2>/dev/null; then printf inherited; else printf closed; fi"
        let result = OwnedChildProcessExecutor.run(
            path: "/bin/sh",
            arguments: ["-c", probe],
            timeout: 5,
            outputLimitPerStream: 1_024
        )

        XCTAssertEqual(result.terminal, .exited(status: 0))
        XCTAssertEqual(result.stdout, "closed")
    }

    func test_超时_忽略TERM时升级SIGKILL() throws {
        // `exec` 保证 shell 与 sleep 是同一 owned PID，不留下继承 pipe 的孙进程。
        let script = "trap '' TERM; exec /bin/sleep 30"
        let shell = SubprocessExecutor.AllowEntry(executable: "/bin/sh",
                                                  argsPrefix: ["-c", script])
        let exec = SubprocessExecutor(allowlist: [shell], timeout: 0.2, dryRun: false)
        let start = Date()
        let r = try exec.run(executable: "/bin/sh", args: ["-c", script])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r.exitCode, -2)
        XCTAssertTrue(r.output.contains("SIGKILL sent"), "忽略 TERM 时必须升级 SIGKILL：\(r.output)")
        XCTAssertLessThan(elapsed, 5)
    }

    // MARK: - 10. launch 失败：不存在路径 → exitCode = -1

    /// PITFALL：launch 失败必须**不抛异常**而是返回 -1（与 MaintenanceCommandResult 同构），
    /// 否则上层 UI 走 do-catch 会被打断，单条失败拖垮整批维护任务。
    func test_错误的executable路径_返回exitCode_minus1() throws {
        let bad = SubprocessExecutor.AllowEntry(executable: "/usr/bin/notexist",
                                                argsPrefix: [])
        let exec = SubprocessExecutor(allowlist: [bad], timeout: 1, dryRun: false)
        let r = try exec.run(executable: "/usr/bin/notexist", args: ["--whatever"])
        XCTAssertEqual(r.exitCode, -1, "launch 失败必须返回 -1，得到 \(r.exitCode)")
        XCTAssertTrue(r.output.contains("launch failed"),
                      "launch 失败输出必须含 'launch failed'：\(r.output)")
    }
}

private final class ManagedSubmissionOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class OwnedChildPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: pid_t?

    func store(_ pid: pid_t) {
        lock.lock()
        storage = pid
        lock.unlock()
    }

    var value: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// v2026.07.17：`onStdoutChunk` 在 utility reader queue 调用，测试 recorder 与生产
/// 使用方一样通过锁建立 Sendable 边界；禁止用非隔离数组掩盖数据竞争。
private final class OwnedStdoutChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var string: String {
        String(data: data, encoding: .utf8) ?? ""
    }
}

private final class OwnedCancellationCheckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterCheckCount: Int
    private var checkCount = 0

    init(cancelAfterCheckCount: Int) {
        self.cancelAfterCheckCount = cancelAfterCheckCount
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checkCount += 1
        return checkCount >= cancelAfterCheckCount
    }
}
