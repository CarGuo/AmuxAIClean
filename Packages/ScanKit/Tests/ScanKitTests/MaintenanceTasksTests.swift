import XCTest
@testable import ScanKit

/// Mole 对齐 M3-T5：MaintenanceTasks 行为契约。
final class MaintenanceTasksTests: XCTestCase {

    // MARK: - Task 元数据

    func test_allCases_包含_2_个_user_space_任务() {
        XCTAssertEqual(Set(MaintenanceTasks.Task.allCases), [
            .flushQuickLookCache, .flushDNSCache
        ])
    }

    func test_displayName_subtitle_非空() {
        for t in MaintenanceTasks.Task.allCases {
            XCTAssertFalse(t.displayName.isEmpty)
            XCTAssertFalse(t.subtitle.isEmpty)
        }
    }

    // MARK: - 命令路径契约（防止有人不小心改成 sudo）

    func test_qlmanage_路径正确_只跑_r() {
        let cmd = MaintenanceTasks.qlmanageCommand
        XCTAssertEqual(cmd.launchPath, "/usr/bin/qlmanage")
        XCTAssertEqual(cmd.arguments, ["-r"])
    }

    func test_dscacheutil_路径正确_只跑_flushcache() {
        let cmd = MaintenanceTasks.dnsFlushCommand
        XCTAssertEqual(cmd.launchPath, "/usr/bin/dscacheutil")
        XCTAssertEqual(cmd.arguments, ["-flushcache"])
    }

    // MARK: - 编排（fake runner）

    func test_run_单任务_把_exit0_映射为_succeeded_true() {
        let fake = FakeMaintenanceRunner(results: [.init(exitCode: 0, output: "ok")])
        let outcome = MaintenanceTasks(runner: fake).run(.flushDNSCache)
        XCTAssertEqual(outcome.task, .flushDNSCache)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.log, "ok")
        XCTAssertEqual(fake.executedCommands.count, 1)
        XCTAssertEqual(fake.executedCommands[0].launchPath, "/usr/bin/dscacheutil")
    }

    func test_run_单任务_非零_exit_映射为_succeeded_false() {
        let fake = FakeMaintenanceRunner(results: [.init(exitCode: 1, output: "boom")])
        let outcome = MaintenanceTasks(runner: fake).run(.flushQuickLookCache)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.log, "boom")
    }

    func test_runAll_按顺序执行_默认全部_2_任务() {
        let fake = FakeMaintenanceRunner(results: [
            .init(exitCode: 0, output: "ql"),
            .init(exitCode: 0, output: "dns")
        ])
        let outcomes = MaintenanceTasks(runner: fake).runAll()
        XCTAssertEqual(outcomes.map(\.task),
                       [.flushQuickLookCache, .flushDNSCache])
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(fake.executedCommands.count, 2)
    }

    func test_runAll_部分失败_其他任务继续执行() {
        let fake = FakeMaintenanceRunner(results: [
            .init(exitCode: 7, output: "ql failed"),
            .init(exitCode: 0, output: "ok")
        ])
        let outcomes = MaintenanceTasks(runner: fake).runAll()
        XCTAssertEqual(outcomes.count, 2, "中间失败不应中断后续任务")
        XCTAssertFalse(outcomes[0].succeeded)
        XCTAssertTrue(outcomes[1].succeeded)
    }

    func test_runAll_指定子集_只跑指定任务() {
        let fake = FakeMaintenanceRunner(results: [
            .init(exitCode: 0, output: "ok"),
            .init(exitCode: 0, output: "ok")
        ])
        let outcomes = MaintenanceTasks(runner: fake)
            .runAll([.flushQuickLookCache, .flushDNSCache])
        XCTAssertEqual(outcomes.map(\.task), [.flushQuickLookCache, .flushDNSCache])
        XCTAssertEqual(fake.executedCommands.count, 2)
    }

    // MARK: - 生产 runner 的 owned-child 合同（仅测试无副作用 fixture）

    /// v2026.07.16：runner 不再 wait-then-read；stdout/stderr 同时超过单个 pipe 常见容量
    /// 也必须完整收敛。这里只执行 shell 输出 fixture，不触发任何真实维护命令。
    func test_defaultRunner_并发排空stdout与stderr() {
        let script = """
        (i=0; while [ $i -lt 4096 ]; do printf 'o'; i=$((i+1)); done) &
        (i=0; while [ $i -lt 4096 ]; do printf 'e' >&2; i=$((i+1)); done) &
        wait
        """
        let result = DefaultMaintenanceRunner(timeout: 5).execute(MaintenanceCommand(
            launchPath: "/bin/sh",
            arguments: ["-c", script]
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.utf8.count, 8_192)
        XCTAssertFalse(result.output.contains("output incomplete"))
    }

    /// v2026.07.16：timeout fixture 使用单一 `/bin/sleep` child，验证共享 owned waiter
    /// 返回明确 -2；不运行 qlmanage、dscacheutil 或 simctl。
    func test_defaultRunner_超时收敛为minus2() {
        let startedAt = Date()
        let result = DefaultMaintenanceRunner(timeout: 0.05).execute(MaintenanceCommand(
            launchPath: "/bin/sleep",
            arguments: ["30"]
        ))

        XCTAssertEqual(result.exitCode, -2)
        XCTAssertTrue(result.output.contains("timeout"))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }
}

// MARK: - Fake runner

private final class FakeMaintenanceRunner: MaintenanceCommandRunning, @unchecked Sendable {
    private var results: [MaintenanceCommandResult]
    var executedCommands: [MaintenanceCommand] = []

    init(results: [MaintenanceCommandResult]) {
        self.results = results
    }

    func execute(_ command: MaintenanceCommand) -> MaintenanceCommandResult {
        executedCommands.append(command)
        guard !results.isEmpty else {
            return MaintenanceCommandResult(exitCode: -99, output: "no result configured")
        }
        return results.removeFirst()
    }
}
