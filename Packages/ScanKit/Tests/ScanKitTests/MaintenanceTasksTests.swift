import XCTest
@testable import ScanKit

/// Mole 对齐 M3-T5：MaintenanceTasks 行为契约。
final class MaintenanceTasksTests: XCTestCase {

    // MARK: - Task 元数据

    func test_allCases_包含_3_个_user_space_任务() {
        XCTAssertEqual(Set(MaintenanceTasks.Task.allCases), [
            .rebuildLaunchServices, .flushQuickLookCache, .flushDNSCache
        ])
    }

    func test_displayName_subtitle_非空() {
        for t in MaintenanceTasks.Task.allCases {
            XCTAssertFalse(t.displayName.isEmpty)
            XCTAssertFalse(t.subtitle.isEmpty)
        }
    }

    // MARK: - 命令路径契约（防止有人不小心改成 sudo）

    func test_lsregister_路径正确_且不含_sudo() {
        let cmd = MaintenanceTasks.lsregisterCommand
        XCTAssertTrue(cmd.launchPath.hasSuffix("/lsregister"))
        XCTAssertFalse(cmd.launchPath.contains("sudo"))
        XCTAssertEqual(cmd.arguments,
                       ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"])
    }

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
        let outcome = MaintenanceTasks(runner: fake).run(.rebuildLaunchServices)
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.log, "boom")
    }

    func test_runAll_按顺序执行_默认全部_3_任务() {
        let fake = FakeMaintenanceRunner(results: [
            .init(exitCode: 0, output: "lsreg"),
            .init(exitCode: 0, output: "ql"),
            .init(exitCode: 0, output: "dns")
        ])
        let outcomes = MaintenanceTasks(runner: fake).runAll()
        XCTAssertEqual(outcomes.map(\.task),
                       [.rebuildLaunchServices, .flushQuickLookCache, .flushDNSCache])
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(fake.executedCommands.count, 3)
    }

    func test_runAll_部分失败_其他任务继续执行() {
        let fake = FakeMaintenanceRunner(results: [
            .init(exitCode: 0, output: "ok"),
            .init(exitCode: 7, output: "ql failed"),
            .init(exitCode: 0, output: "ok")
        ])
        let outcomes = MaintenanceTasks(runner: fake).runAll()
        XCTAssertEqual(outcomes.count, 3, "中间失败不应中断后续任务")
        XCTAssertTrue(outcomes[0].succeeded)
        XCTAssertFalse(outcomes[1].succeeded)
        XCTAssertTrue(outcomes[2].succeeded)
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
