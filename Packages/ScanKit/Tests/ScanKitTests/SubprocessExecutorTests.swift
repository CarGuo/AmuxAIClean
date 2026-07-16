import XCTest
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

    func test_超时_忽略TERM时升级SIGKILL() throws {
        let shell = SubprocessExecutor.AllowEntry(executable: "/bin/sh",
                                                  argsPrefix: ["-c", "trap '' TERM; sleep 30"])
        let exec = SubprocessExecutor(allowlist: [shell], timeout: 0.2, dryRun: false)
        let start = Date()
        let r = try exec.run(executable: "/bin/sh", args: ["-c", "trap '' TERM; sleep 30"])
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
