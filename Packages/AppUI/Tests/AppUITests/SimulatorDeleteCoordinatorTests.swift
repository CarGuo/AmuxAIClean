import XCTest
import Foundation
import ScanKit
@testable import AppUI

/// Simulator system-managed uninstall contract tests.
///
/// No test in this file starts a real `simctl` process. Normal execution tests inject a dry-run
/// executor; the stall contract uses only `/bin/sleep` to prove detaching never kills a process.
final class SimulatorDeleteCoordinatorTests: XCTestCase {
    private static let boundedLedgerProcess = SimulatorLedgerProcessIdentity(
        pid: 52_001,
        startTimeSeconds: 300,
        startTimeMicroseconds: 3
    )
    private let deviceUUID = "11111111-2222-3333-4444-555555555555"
    private let runtimeUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let secondRuntimeUUID = "12345678-1234-1234-1234-123456789abc"
    private let reviewSessionID = UUID(uuidString: "99999999-1111-2222-3333-444444444444")!

    private var reviewIdentity: SimulatorManagedReviewIdentity {
        SimulatorManagedReviewIdentity(sessionID: reviewSessionID, revision: 7)
    }

    private var freshReviewIdentity: SimulatorManagedReviewIdentity {
        SimulatorManagedReviewIdentity(sessionID: reviewSessionID, revision: 8)
    }

    private var nextReviewIdentity: SimulatorManagedReviewIdentity {
        SimulatorManagedReviewIdentity(sessionID: reviewSessionID, revision: 9)
    }

    func test_prepare_emptySelection_returnsEmpty() {
        let coordinator = makeCoordinator()

        XCTAssertEqual(
            coordinator.prepare(cards: [deviceCard()], cardHits: [:], selected: []),
            .empty
        )
    }

    func test_prepare_filesystemSelection_neverEntersManagedPlan() {
        let coordinator = makeCoordinator()
        let filesystemHit = hit(
            name: "DerivedData",
            path: "/tmp/DerivedData",
            identifier: nil
        )

        let plan = coordinator.prepare(
            cards: [filesystemCard()],
            cardHits: [filesystemCardID: [filesystemHit]],
            selected: [filesystemHit.id]
        )

        XCTAssertEqual(plan, .empty)
    }

    func test_prepare_deviceAndRuntime_buildsTypedCommandsFromManagedRecipes() throws {
        let coordinator = makeCoordinator()
        let device = hit(
            name: "iPhone 17",
            path: "/tmp/device",
            sizeBytes: 1_024,
            identifier: deviceUUID
        )
        let runtime = hit(
            name: "iOS 26.2",
            path: "/tmp/runtime",
            sizeBytes: 8_000_000_000,
            identifier: runtimeUUID
        )

        let plan = coordinator.prepare(
            cards: [deviceCard(), runtimeCard()],
            cardHits: [
                deviceCardID: [device],
                runtimeCardID: [runtime],
            ],
            selected: [device.id, runtime.id]
        )

        guard case let .ready(items) = plan else {
            return XCTFail("Valid managed device/runtime selections must produce a ready plan")
        }
        XCTAssertEqual(items.map(\.hitID), [device.id, runtime.id])
        XCTAssertEqual(items.map(\.kind), [.simulatorDevice, .simulatorRuntime])
        XCTAssertEqual(items.map(\.sizeBytes), [1_024, 8_000_000_000])
        XCTAssertEqual(items[0].executable, "/usr/bin/xcrun")
        XCTAssertEqual(items[0].args, ["simctl", "delete", deviceUUID])
        XCTAssertEqual(items[1].executable, "/usr/bin/xcrun")
        XCTAssertEqual(items[1].args, ["simctl", "runtime", "delete", runtimeUUID])
    }

    func test_prepare_missingManagedIdentifier_returnsInvalid() {
        let coordinator = makeCoordinator()
        let runtime = hit(
            name: "Legacy runtime",
            path: "/tmp/legacy-runtime",
            identifier: nil
        )

        let plan = coordinator.prepare(
            cards: [runtimeCard()],
            cardHits: [runtimeCardID: [runtime]],
            selected: [runtime.id]
        )

        guard case let .invalid(reason) = plan else {
            return XCTFail("A non-deletable runtime without a UUID must be rejected")
        }
        XCTAssertTrue(reason.contains(runtime.displayName))
    }

    func test_prepare_deviceRejectsMalformedUUID() {
        let coordinator = makeCoordinator()
        let device = hit(
            name: "Malformed device",
            path: "/tmp/malformed-device",
            identifier: "not-a-uuid"
        )

        let plan = coordinator.prepare(
            cards: [deviceCard()],
            cardHits: [deviceCardID: [device]],
            selected: [device.id]
        )

        guard case let .invalid(reason) = plan else {
            return XCTFail("A malformed Simulator device identifier must be rejected")
        }
        XCTAssertTrue(reason.contains(device.displayName))
    }

    func test_prepare_runtimeRejectsSemanticIdentifierAndRequiresImageUUID() {
        let coordinator = makeCoordinator()
        let runtime = hit(
            name: "iOS 18.0",
            path: "/tmp/semantic-runtime",
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        )

        let plan = coordinator.prepare(
            cards: [runtimeCard()],
            cardHits: [runtimeCardID: [runtime]],
            selected: [runtime.id]
        )

        guard case let .invalid(reason) = plan else {
            return XCTFail("Xcode runtime delete requires the image UUID, not the semantic runtime ID")
        }
        XCTAssertTrue(reason.contains(runtime.displayName))
    }

    func test_prepare_拒绝重复managedUUID与非文件URL() {
        let coordinator = makeCoordinator()
        let first = hit(
            name: "Duplicate A",
            path: "/tmp/duplicate-a",
            identifier: runtimeUUID
        )
        let second = hit(
            name: "Duplicate B",
            path: "/tmp/duplicate-b",
            identifier: runtimeUUID.uppercased()
        )
        let duplicatePlan = coordinator.prepare(
            cards: [runtimeCard()],
            cardHits: [runtimeCardID: [first, second]],
            selected: [first.id, second.id]
        )
        guard case .invalid = duplicatePlan else {
            return XCTFail("同一 managed UUID 的两个 row 必须整批拒绝")
        }

        let remote = WorkflowScanHit(
            url: URL(string: "https://example.invalid/runtime")!,
            sizeBytes: 1,
            displayName: "Remote runtime",
            note: nil,
            managedUninstallIdentifier: secondRuntimeUUID
        )
        let remotePlan = coordinator.prepare(
            cards: [runtimeCard()],
            cardHits: [runtimeCardID: [remote]],
            selected: [remote.id]
        )
        guard case .invalid = remotePlan else {
            return XCTFail("managed resource 必须绑定无歧义绝对 file URL")
        }
    }

    func test_prepare_whenSimulatorIsRunning_blocksEveryManagedItem() {
        let coordinator = makeCoordinator(running: true)
        let runtime = hit(
            name: "iOS 26.2",
            path: "/tmp/runtime-running",
            identifier: runtimeUUID
        )

        let plan = coordinator.prepare(
            cards: [runtimeCard()],
            cardHits: [runtimeCardID: [runtime]],
            selected: [runtime.id]
        )

        XCTAssertEqual(
            plan,
            .blockedSimulatorRunning(displayNames: [runtime.displayName])
        )
    }

    func test_executeManaged_publishesOrderedPerItemProgressAndReceipt() async throws {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(
                hitID: "/tmp/device-progress",
                name: "iPhone 17",
                kind: .simulatorDevice,
                identifier: deviceUUID
            ),
            makeItem(
                hitID: "/tmp/runtime-progress",
                name: "iOS 26.2",
                kind: .simulatorRuntime,
                identifier: runtimeUUID
            ),
        ]
        let recorder = ManagedEventRecorder()
        let control = SimulatorDeleteCoordinator.StopControl()

        let completion = await coordinator.executeManaged(
            items: items,
            reviewIdentity: reviewIdentity,
            stopControl: control
        ) { event in
            await recorder.append(event)
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 8)
        assertStarted(events[0], index: 1, total: 2, hitID: items[0].hitID)
        assertSubmitted(events[1], index: 1, total: 2, hitID: items[0].hitID)
        assertRunning(events[2], index: 1, total: 2, hitID: items[0].hitID)
        assertFinished(events[3], index: 1, total: 2, hitID: items[0].hitID)
        assertStarted(events[4], index: 2, total: 2, hitID: items[1].hitID)
        assertSubmitted(events[5], index: 2, total: 2, hitID: items[1].hitID)
        assertRunning(events[6], index: 2, total: 2, hitID: items[1].hitID)
        assertFinished(events[7], index: 2, total: 2, hitID: items[1].hitID)
        XCTAssertEqual(completion.succeededCount, 2)
        XCTAssertEqual(completion.failedCount, 0)
        XCTAssertTrue(completion.outcomes.allSatisfy(\.wasSubmitted))
        XCTAssertTrue(completion.skippedItems.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(completion.receipt).submittedItemIDs,
            items.map(\.hitID)
        )
    }

    func test_executeManaged_stopAfterCurrent_skipsOnlyUnsubmittedItems() async throws {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(
                hitID: "/tmp/runtime-stop-1",
                name: "iOS 26.0",
                kind: .simulatorRuntime,
                identifier: runtimeUUID
            ),
            makeItem(
                hitID: "/tmp/runtime-stop-2",
                name: "iOS 26.1",
                kind: .simulatorRuntime,
                identifier: secondRuntimeUUID
            ),
            makeItem(
                hitID: "/tmp/device-stop-3",
                name: "iPhone 17",
                kind: .simulatorDevice,
                identifier: deviceUUID
            ),
        ]
        let recorder = ManagedEventRecorder()
        let control = SimulatorDeleteCoordinator.StopControl()

        let completion = await coordinator.executeManaged(
            items: items,
            reviewIdentity: reviewIdentity,
            stopControl: control
        ) { event in
            await recorder.append(event)
            if case .started(index: 1, total: _, item: _) = event {
                // A submitted system uninstall is allowed to finish. The stop request is
                // observed only at the next item boundary.
                await control.requestStop()
            }
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 4)
        assertStarted(events[0], index: 1, total: 3, hitID: items[0].hitID)
        assertSubmitted(events[1], index: 1, total: 3, hitID: items[0].hitID)
        assertRunning(events[2], index: 1, total: 3, hitID: items[0].hitID)
        assertFinished(events[3], index: 1, total: 3, hitID: items[0].hitID)
        XCTAssertEqual(completion.outcomes.map(\.item.hitID), [items[0].hitID])
        XCTAssertEqual(completion.outcomes.map(\.wasSubmitted), [true])
        XCTAssertEqual(completion.skippedItems.map(\.hitID), [items[1].hitID, items[2].hitID])
        XCTAssertEqual(
            try XCTUnwrap(completion.receipt).submittedItemIDs,
            [items[0].hitID],
            "The receipt must contain only the command that crossed the submission boundary"
        )
    }

    func test_executeManaged_stoppedBeforeSubmission_hasNoReceiptAndSkipsAllItems() async {
        let coordinator = makeCoordinator()
        let items = [
            makeItem(
                hitID: "/tmp/runtime-prestopped",
                name: "iOS 26.2",
                kind: .simulatorRuntime,
                identifier: runtimeUUID
            ),
        ]
        let recorder = ManagedEventRecorder()
        let control = SimulatorDeleteCoordinator.StopControl()
        await control.requestStop()

        let completion = await coordinator.executeManaged(
            items: items,
            reviewIdentity: reviewIdentity,
            stopControl: control
        ) { event in
            await recorder.append(event)
        }

        XCTAssertNil(completion.receipt)
        XCTAssertTrue(completion.outcomes.isEmpty)
        XCTAssertEqual(completion.skippedItems.map(\.hitID), items.map(\.hitID))
        let events = await recorder.snapshot()
        XCTAssertTrue(events.isEmpty)
    }

    func test_executeManaged_preSubmissionAllowlistRejection_hasNoReceipt() async {
        let coordinator = makeCoordinator(allowlist: [])
        let item = makeItem(
            hitID: "/tmp/runtime-failure",
            name: "iOS 26.2",
            kind: .simulatorRuntime,
            identifier: runtimeUUID
        )

        let completion = await coordinator.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }

        XCTAssertEqual(completion.succeededCount, 0)
        XCTAssertEqual(completion.failedCount, 1)
        XCTAssertEqual(completion.outcomes.first?.exitCode, -3)
        XCTAssertEqual(completion.outcomes.first?.wasSubmitted, false)
        XCTAssertNil(
            completion.receipt,
            "An allowlist rejection happens before Process submission and must not mint a receipt"
        )
    }

    func test_executeManaged_processLaunchFailure_hasNoSubmissionReceipt() async {
        let missingExecutable = "/usr/bin/definitely-not-present-gsycleanmac"
        let allowEntry = SubprocessExecutor.AllowEntry(
            executable: missingExecutable,
            argsPrefix: ManagedUninstallRecipe.simulatorRuntime.argsPrefix
        )
        let ledger = InMemorySimulatorManagedOperationLedger()
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: [allowEntry],
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: ledger
        )
        let item = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-launch-failure",
            displayName: "Runtime launch failure",
            kind: .simulatorRuntime,
            executable: missingExecutable,
            args: ManagedUninstallRecipe.simulatorRuntime.argsPrefix + [runtimeUUID]
        )

        let completion = await coordinator.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }

        XCTAssertEqual(completion.outcomes.first?.exitCode, -1)
        XCTAssertEqual(completion.outcomes.first?.wasSubmitted, false)
        XCTAssertNil(completion.receipt,
                     "Process.run 失败没有跨过提交边界，不能铸造 receipt")
        XCTAssertEqual(
            ledger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .absent,
            "Process.run launch failure 必须回滚提交前 intent tombstone"
        )
    }

    /// **v2026.07.16 回归合同**：整批开始时安全不代表下一项提交时仍安全。
    /// 第一项结束后若 Simulator 被启动，第二项必须保持未提交并给出明确中断原因。
    func test_executeManaged_每一项提交前重验Simulator运行态() async throws {
        let runningProbe = LockedRunningSequence([false, true])
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { runningProbe.next() },
            bootedDeviceProbe: { .safeToSubmit }
        )
        let items = [
            makeItem(
                hitID: "/tmp/runtime-revalidate-1",
                name: "iOS 26.0",
                kind: .simulatorRuntime,
                identifier: runtimeUUID
            ),
            makeItem(
                hitID: "/tmp/runtime-revalidate-2",
                name: "iOS 26.1",
                kind: .simulatorRuntime,
                identifier: secondRuntimeUUID
            ),
        ]
        let recorder = ManagedEventRecorder()

        let completion = await coordinator.executeManaged(
            items: items,
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { event in
            await recorder.append(event)
        }

        XCTAssertEqual(completion.outcomes.map(\.item.hitID), items.map(\.hitID))
        XCTAssertEqual(completion.outcomes.last?.failureReason, .simulatorOrDeviceActive)
        XCTAssertTrue(completion.skippedItems.isEmpty)
        XCTAssertEqual(completion.interruptionReason, .simulatorStarted)
        XCTAssertEqual(try XCTUnwrap(completion.receipt).submittedItemIDs, [items[0].hitID])
        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 7)
        assertStarted(events[4], index: 2, total: 2, hitID: items[1].hitID)
        assertBlockedSimulatorRunning(
            events[5],
            index: 2,
            total: 2,
            hitID: items[1].hitID
        )
    }

    /// **v2026.07.16 P1 TOCTOU 回归**：权威 Booted-device 查询可阻塞数秒。
    /// 模拟 Simulator.app 在该查询期间启动，最后的 GUI probe 必须看到它，
    /// 且不得跨过 Process.run 或在持久 ledger 留下虚假 pending。
    func test_executeManaged_Booted查询期间Simulator启动_最后GUI复核阻断且零提交() async {
        let probes = LockedSubmissionOrderProbe()
        let ledger = InMemorySimulatorManagedOperationLedger()
        let args = ManagedUninstallRecipe.simulatorRuntime.argsPrefix + [runtimeUUID]
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: [SubprocessExecutor.AllowEntry(
                    executable: "/bin/echo",
                    argsPrefix: ManagedUninstallRecipe.simulatorRuntime.argsPrefix
                )],
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: { probes.isSimulatorRunning() },
            bootedDeviceProbe: { probes.queryBootedDevicesAndStartSimulator() },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: ledger
        )
        let item = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-gui-toctou",
            displayName: "Runtime GUI TOCTOU",
            kind: .simulatorRuntime,
            executable: "/bin/echo",
            args: args
        )
        let recorder = ManagedEventRecorder()

        let completion = await coordinator.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { event in
            await recorder.append(event)
        }

        XCTAssertEqual(probes.snapshot(), ["booted", "simulator"])
        XCTAssertEqual(completion.outcomes.first?.failureReason, .simulatorOrDeviceActive)
        XCTAssertEqual(completion.outcomes.first?.wasSubmitted, false)
        XCTAssertNil(completion.receipt)
        XCTAssertEqual(
            ledger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .absent,
            "GUI 复核阻断发生在 ledger reserve 之前，不得留下 tombstone"
        )
        let events = await recorder.snapshot()
        XCTAssertFalse(events.contains { event in
            if case .submitted = event { return true }
            return false
        }, "Simulator 启动后不得跨过 Process.run 提交边界")
    }

    /// 观察窗口只结束 UI 等待，不得把仍在进行的 CoreSimulator 事务记成失败或成功。
    /// 当前项 unknown 后，后续项也不能继续提交；用户稍后由重新扫描完成对账。
    func test_executeManaged_stall后返回unknown并停止后续提交_不强杀当前进程() async throws {
        let sleepEntry = SubprocessExecutor.AllowEntry(
            executable: "/bin/sleep",
            argsPrefix: ["0.2"]
        )
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: [sleepEntry],
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedObservationLimit: 0.03
        )
        let first = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-stalled-1",
            displayName: "iOS 26.0",
            kind: .simulatorRuntime,
            executable: "/bin/sleep",
            args: ["0.2"]
        )
        let second = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-stalled-2",
            displayName: "iOS 26.1",
            kind: .simulatorRuntime,
            executable: "/bin/sleep",
            args: ["0.2"]
        )
        let recorder = ManagedEventRecorder()
        let startedAt = Date()

        let completion = await coordinator.executeManaged(
            items: [first, second],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { event in
            await recorder.append(event)
        }
        let detachedAt = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(detachedAt, 0.15, "UI 应在观察窗口后脱离，不能等完整 sleep")
        XCTAssertEqual(completion.succeededCount, 0)
        XCTAssertEqual(completion.failedCount, 0)
        XCTAssertEqual(completion.unknownCount, 1)
        XCTAssertEqual(completion.outcomes.first?.status, .unknownAfterStall)
        XCTAssertEqual(completion.skippedItems.map(\.hitID), [second.hitID])
        XCTAssertEqual(completion.interruptionReason, .currentItemStatusUnknown)
        XCTAssertEqual(try XCTUnwrap(completion.receipt).submittedItemIDs, [first.hitID])
        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 5)
        assertStalled(events[3], index: 1, total: 2, hitID: first.hitID)

        // 同 UUID 在迟到终态被消费前必须原子禁重；不能因 UI 已返回 unknown 再提交一次。
        let duplicate = await coordinator.executeManaged(
            items: [first],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(duplicate.outcomes.first?.failureReason, .duplicatePendingOperation)
        XCTAssertNil(duplicate.receipt)

        // 消费迟到终态同时证明唯一 monitor 一直在排空流；终态为自然 exit 0，且 registry
        // tombstone 随 reconciliation 收敛，不永久污染后续会话测试。
        let reconciled = await coordinator.awaitReconciledOutcome(for: first)
        XCTAssertEqual(reconciled?.status, .confirmedTerminal(exitCode: 0))
        let pendingCount = await coordinator.pendingManagedOperationCount()
        XCTAssertEqual(pendingCount, 0)
    }

    /// **v2026.07.16 跨重启合同**：新 Coordinator/ledger 实例仍必须看到旧 tombstone。
    /// 资源仍在权威清单时拒绝重提；只有 authority 明确 absent 才清记录，且当前陈旧
    /// frozen row 仍不发送 delete，要求重新扫描。
    func test_persistentLedger_跨Coordinator禁重_仅权威absent后清除() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let item = makeItem(
            hitID: "/tmp/runtime-persistent-ledger",
            name: "iOS persistent ledger",
            kind: .simulatorRuntime,
            identifier: runtimeUUID
        )

        let firstLedger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let first = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: firstLedger
        )
        let firstCompletion = await first.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(firstCompletion.succeededCount, 1)
        XCTAssertEqual(
            firstLedger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .terminal(exitCode: 0),
            "dry-run 的 confirmed terminal 也必须写入独立阶段，不能退化为模糊 pending"
        )

        // 模拟 App 重启：重新构造 ledger + coordinator，不能依赖旧 actor 内存。
        let secondLedger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let second = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: secondLedger
        )
        let blocked = await second.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(blocked.outcomes.first?.failureReason, .persistentPendingOperation)
        XCTAssertNil(blocked.receipt)

        let thirdLedger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let third = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .absent },
            managedOperationLedger: thirdLedger
        )
        let reconciled = await third.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(reconciled.outcomes.first?.failureReason, .resourceAlreadyAbsent)
        XCTAssertNil(reconciled.receipt)
        XCTAssertEqual(thirdLedger.state(identifier: runtimeUUID, kind: .simulatorRuntime), .absent)
    }

    /// **v2026.07.16 根因回归**：reserve 本身不等于命令已提交。只有 owner 身份仍活跃
    /// 才能阻止并发实例；模拟 App 重启后，死亡 owner 的 reserved 可由新一轮用户复核
    /// 清除并重新提交。测试只用 dry-run，绝不执行真实 simctl。
    func test_persistentLedger_死亡owner的reserved可由新复核恢复_submitted仍禁重() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerPhases-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let firstIdentity = SimulatorLedgerProcessIdentity(
            pid: 41_001,
            startTimeSeconds: 100,
            startTimeMicroseconds: 1
        )
        let secondIdentity = SimulatorLedgerProcessIdentity(
            pid: 41_002,
            startTimeSeconds: 200,
            startTimeMicroseconds: 2
        )
        let firstLedger = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { firstIdentity },
            processLivenessProbe: { $0 == firstIdentity ? .active : .inactive }
        )
        guard case .reserved = firstLedger.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else {
            return XCTFail("fixture must reserve the first attempt")
        }
        XCTAssertEqual(
            firstLedger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .reservedByActiveProcess
        )

        // 模拟新 App 进程：旧 PID + start time 已不存在，因此 reserved 不是 in-flight。
        let restartedLedger = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { secondIdentity },
            processLivenessProbe: { identity in
                identity == firstIdentity ? .inactive : .active
            }
        )
        XCTAssertEqual(
            restartedLedger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .staleReservation
        )
        let item = makeItem(
            hitID: "/tmp/runtime-stale-reservation",
            name: "iOS stale reservation",
            kind: .simulatorRuntime,
            identifier: runtimeUUID
        )
        let restarted = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(timeout: 1, dryRun: true),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: restartedLedger
        )
        let completion = await restarted.executeManaged(
            items: [item],
            reviewIdentity: freshReviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(completion.succeededCount, 1)
        XCTAssertNotNil(completion.receipt)
        XCTAssertEqual(
            restartedLedger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .terminal(exitCode: 0)
        )

        // 相反，submitted 即使 owner 已死亡也仍可能是跨重启继续运行的 CoreSimulator
        // 事务；它必须保留 fail-closed，不能套用 stale-reserved 恢复规则。
        let submittedURL = directory.appendingPathComponent("submitted.json")
        let submittedLedger = PersistentSimulatorManagedOperationLedger(
            fileURL: submittedURL,
            processIdentityProvider: { firstIdentity },
            processLivenessProbe: { _ in .active }
        )
        guard case .reserved(let submittedAttemptID) = submittedLedger.reserve(
            identifier: secondRuntimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else {
            return XCTFail("fixture must reserve the submitted attempt")
        }
        XCTAssertTrue(
            submittedLedger.markSubmitted(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                expectedAttemptID: submittedAttemptID
            )
        )
        let submittedAfterRestart = PersistentSimulatorManagedOperationLedger(
            fileURL: submittedURL,
            processIdentityProvider: { secondIdentity },
            processLivenessProbe: { _ in .inactive }
        )
        XCTAssertEqual(
            submittedAfterRestart.state(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime
            ),
            .submitted
        )
        XCTAssertFalse(
            submittedAfterRestart.clearStaleReservationForFreshReview(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                expectedAttemptID: submittedAttemptID,
                candidateReviewIdentity: freshReviewIdentity
            )
        )
        XCTAssertTrue(
            submittedLedger.recordConfirmedTerminal(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                expectedAttemptID: submittedAttemptID,
                exitCode: 9
            )
        )
        XCTAssertEqual(
            submittedAfterRestart.state(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime
            ),
            .terminal(exitCode: 9)
        )
        XCTAssertTrue(
            submittedAfterRestart.clearAfterConfirmedTerminalFailure(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                expectedAttemptID: submittedAttemptID
            )
        )
        XCTAssertEqual(
            submittedAfterRestart.state(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime
            ),
            .absent
        )
    }

    /// **v2026.07.16 根因回归**：真实非零 terminationStatus 证明子进程已结束，不能像
    /// submitted/unknown 一样永久锁住同一 UUID。用 `/usr/bin/false` 作为受控替身，参数
    /// 仍保持 managed recipe 形状；测试不会启动 xcrun 或触碰任何 Simulator 资源。
    func test_executeManaged_confirmedTerminalFailure清ledger并允许下一次复核重试() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerTerminal-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ledger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let falseEntry = SubprocessExecutor.AllowEntry(
            executable: "/usr/bin/false",
            argsPrefix: ManagedUninstallRecipe.simulatorRuntime.argsPrefix
        )
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: [falseEntry],
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: { false },
            bootedDeviceProbe: { .safeToSubmit },
            managedResourceAuthorityProbe: { _, _ in .present },
            managedOperationLedger: ledger
        )
        let item = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-terminal-failure",
            displayName: "iOS terminal failure",
            kind: .simulatorRuntime,
            executable: "/usr/bin/false",
            args: ManagedUninstallRecipe.simulatorRuntime.argsPrefix + [runtimeUUID]
        )

        let first = await coordinator.executeManaged(
            items: [item],
            reviewIdentity: reviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(first.outcomes.first?.status, .confirmedTerminal(exitCode: 1))
        XCTAssertEqual(first.outcomes.first?.failureReason, .commandFailed(exitCode: 1))
        XCTAssertNotNil(first.receipt)
        XCTAssertEqual(
            ledger.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .absent,
            "confirmed nonzero 已无活跃进程，terminal 记录应清除而非永久 pending"
        )

        let second = await coordinator.executeManaged(
            items: [item],
            reviewIdentity: nextReviewIdentity,
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }
        XCTAssertEqual(second.outcomes.first?.status, .confirmedTerminal(exitCode: 1))
        XCTAssertNotEqual(second.outcomes.first?.failureReason, .persistentPendingOperation)
        XCTAssertNotNil(second.receipt, "下一次显式复核必须能够重新跨过提交边界")
        XCTAssertEqual(ledger.state(identifier: runtimeUUID, kind: .simulatorRuntime), .absent)
    }

    func test_persistentLedger_两个实例并发reserve不会丢tombstone() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerRace-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let second = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let identifier = runtimeUUID
        let frozenReviewIdentity = reviewIdentity

        async let firstResult = Task.detached {
            first.reserve(
                identifier: identifier,
                kind: .simulatorRuntime,
                reviewIdentity: frozenReviewIdentity
            )
        }.value
        async let secondResult = Task.detached {
            second.reserve(
                identifier: identifier,
                kind: .simulatorRuntime,
                reviewIdentity: frozenReviewIdentity
            )
        }.value
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter {
            if case .reserved = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyPending }.count, 1)
        XCTAssertEqual(
            first.state(identifier: identifier, kind: .simulatorRuntime),
            .reservedByActiveProcess
        )
    }

    /// **v2026.07.16 P1 ABA 回归**：authority 查询与 clear 是两个事务。迟到的旧查询
    /// 结果只能清它观察到的 attempt，不能把另一个 App 实例刚 reserve/submitted 的替代
    /// attempt 一并删除并重新开放重复提交。
    func test_persistentLedger_迟到authorityClear不能删除replacementAttempt() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerABA-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let firstIdentity = SimulatorLedgerProcessIdentity(
            pid: 42_001,
            startTimeSeconds: 100,
            startTimeMicroseconds: 1
        )
        let secondIdentity = SimulatorLedgerProcessIdentity(
            pid: 42_002,
            startTimeSeconds: 200,
            startTimeMicroseconds: 2
        )
        let first = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { firstIdentity },
            processLivenessProbe: { $0 == firstIdentity ? .active : .inactive }
        )
        guard case .reserved(let firstAttemptID) = first.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else {
            return XCTFail("fixture must reserve first attempt")
        }
        XCTAssertTrue(first.markSubmitted(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: firstAttemptID
        ))

        // Instance A freezes this observation, then blocks in its external authority query.
        let delayedObservation = first.observation(
            identifier: runtimeUUID,
            kind: .simulatorRuntime
        )
        XCTAssertEqual(delayedObservation.state, .submitted)
        XCTAssertEqual(delayedObservation.attemptID, firstAttemptID)

        // Instance B finishes the same reconciliation and clears the old attempt first.
        XCTAssertTrue(first.clearAfterAuthoritativeAbsence(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: firstAttemptID
        ))
        let replacement = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { secondIdentity },
            processLivenessProbe: { $0 == secondIdentity ? .active : .inactive }
        )
        guard case .reserved(let replacementAttemptID) = replacement.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: freshReviewIdentity
        ) else {
            return XCTFail("fixture must reserve replacement attempt")
        }
        XCTAssertNotEqual(replacementAttemptID, firstAttemptID)
        XCTAssertTrue(replacement.markSubmitted(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: replacementAttemptID
        ))

        // Instance A resumes with the stale result. CAS must reject it and preserve replacement.
        XCTAssertFalse(first.clearAfterAuthoritativeAbsence(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: firstAttemptID
        ))
        let current = replacement.observation(
            identifier: runtimeUUID,
            kind: .simulatorRuntime
        )
        XCTAssertEqual(current.state, .submitted)
        XCTAssertEqual(current.attemptID, replacementAttemptID)
    }

    /// v1 never recorded owner PID/start-time or a terminal boundary. It therefore migrates to
    /// submitted with one stable generation and remains fail-closed while the resource is present;
    /// only an authoritative-absence caller may clear that exact migrated attempt.
    func test_persistentLedger_schemaV1保守迁移且token跨实例稳定() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerV1-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = UUID(uuidString: runtimeUUID)!.uuidString.lowercased()
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "records": [
                canonical: [
                    "identifier": canonical,
                    "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                    "submittedIntentAt": ISO8601DateFormatter().string(from: Date()),
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

        let first = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        let firstObservation = first.observation(
            identifier: runtimeUUID,
            kind: .simulatorRuntime
        )
        XCTAssertEqual(firstObservation.state, .submitted)
        let migratedAttemptID = try XCTUnwrap(firstObservation.attemptID)
        XCTAssertEqual(
            first.reserve(
                identifier: runtimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .alreadyPending
        )
        XCTAssertFalse(first.clearAfterConfirmedTerminalFailure(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: migratedAttemptID
        ))

        let restarted = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        XCTAssertEqual(
            restarted.observation(identifier: runtimeUUID, kind: .simulatorRuntime),
            firstObservation,
            "migration token must not be regenerated on every read/restart"
        )
        XCTAssertTrue(restarted.clearAfterAuthoritativeAbsence(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: migratedAttemptID
        ))
        guard case .reserved(let replacementAttemptID) = restarted.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: freshReviewIdentity
        ) else {
            return XCTFail("authoritative absence should permit a fresh reviewed attempt")
        }
        XCTAssertNotEqual(replacementAttemptID, migratedAttemptID)
    }

    /// schema 2 already had owner PID/start-time and lifecycle phases. Migration must preserve
    /// that liveness evidence while assigning one stable generation, so only a proven-dead
    /// reserved owner can be recovered by a fresh review.
    func test_persistentLedger_schemaV2保留owner身份并迁移稳定token() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerV2-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = UUID(uuidString: runtimeUUID)!.uuidString.lowercased()
        let oldIdentity = SimulatorLedgerProcessIdentity(
            pid: 43_001,
            startTimeSeconds: 100,
            startTimeMicroseconds: 1
        )
        let newIdentity = SimulatorLedgerProcessIdentity(
            pid: 43_002,
            startTimeSeconds: 200,
            startTimeMicroseconds: 2
        )
        let payload: [String: Any] = [
            "schemaVersion": 2,
            "records": [
                canonical: [
                    "identifier": canonical,
                    "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                    "owner": [
                        "pid": oldIdentity.pid,
                        "startTimeSeconds": oldIdentity.startTimeSeconds,
                        "startTimeMicroseconds": oldIdentity.startTimeMicroseconds,
                    ],
                    "phase": "reserved",
                    "reservedAt": ISO8601DateFormatter().string(from: Date()),
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

        let restarted = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { newIdentity },
            processLivenessProbe: { $0 == oldIdentity ? .inactive : .active }
        )
        let observation = restarted.observation(
            identifier: runtimeUUID,
            kind: .simulatorRuntime
        )
        XCTAssertEqual(observation.state, .staleReservation)
        let migratedAttemptID = try XCTUnwrap(observation.attemptID)
        let secondRead = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { newIdentity },
            processLivenessProbe: { $0 == oldIdentity ? .inactive : .active }
        ).observation(identifier: runtimeUUID, kind: .simulatorRuntime)
        XCTAssertEqual(secondRead.attemptID, migratedAttemptID)
        XCTAssertTrue(restarted.clearStaleReservationForFreshReview(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: migratedAttemptID,
            candidateReviewIdentity: freshReviewIdentity
        ))
        guard case .reserved(let replacementAttemptID) = restarted.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: freshReviewIdentity
        ) else {
            return XCTFail("dead v2 reserved owner should permit a fresh reviewed attempt")
        }
        XCTAssertNotEqual(replacementAttemptID, migratedAttemptID)
    }

    /// **v2026.07.16 根因回归**：死亡 owner 只能证明旧命令没有提交，不能证明用户已经
    /// 看过一份更新后的扫描结果。同 session 同 revision 必须保留 stale tombstone；只有
    /// 同 session 更高 revision 或不同 session 才能在 ledger 的 flock/CAS 事务内清理。
    func test_persistentLedger_staleReservation只接受更新后的复核代际() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerReviewOrder-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let oldOwner = SimulatorLedgerProcessIdentity(
            pid: 45_001,
            startTimeSeconds: 100,
            startTimeMicroseconds: 1
        )
        let newOwner = SimulatorLedgerProcessIdentity(
            pid: 45_002,
            startTimeSeconds: 200,
            startTimeMicroseconds: 2
        )
        let originalReview = SimulatorManagedReviewIdentity(
            sessionID: reviewSessionID,
            revision: 50
        )
        let original = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { oldOwner },
            processLivenessProbe: { $0 == oldOwner ? .active : .inactive }
        )
        guard case .reserved(let firstAttemptID) = original.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: originalReview
        ) else {
            return XCTFail("fixture must reserve the original reviewed attempt")
        }

        let restarted = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { newOwner },
            processLivenessProbe: { $0 == oldOwner ? .inactive : .active }
        )
        XCTAssertEqual(
            restarted.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .staleReservation
        )
        XCTAssertFalse(restarted.clearStaleReservationForFreshReview(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: firstAttemptID,
            candidateReviewIdentity: originalReview
        ), "同一次复核不能在重启后给自己重新授权")
        XCTAssertEqual(
            restarted.state(identifier: runtimeUUID, kind: .simulatorRuntime),
            .staleReservation
        )

        let higherRevision = SimulatorManagedReviewIdentity(
            sessionID: originalReview.sessionID,
            revision: originalReview.revision + 1
        )
        XCTAssertTrue(restarted.clearStaleReservationForFreshReview(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: firstAttemptID,
            candidateReviewIdentity: higherRevision
        ))

        guard case .reserved(let secondAttemptID) = original.reserve(
            identifier: secondRuntimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: originalReview
        ) else {
            return XCTFail("fixture must reserve a second reviewed attempt")
        }
        let newSession = SimulatorManagedReviewIdentity(sessionID: UUID(), revision: 1)
        XCTAssertTrue(restarted.clearStaleReservationForFreshReview(
            identifier: secondRuntimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: secondAttemptID,
            candidateReviewIdentity: newSession
        ))
    }

    /// **v2026.07.16 根因回归**：PID/start timeval 是跨进程 owner 身份的一部分；零 PID、
    /// 零秒或未归一化 usec 都不能送进 liveness probe。任一坏记录必须让整个 ledger
    /// fail closed，连查询另一 UUID 的“absent”与新 reserve 都不能放行。
    func test_persistentLedger_malformedOwnerShape使整个ledgerFailClosed() throws {
        let malformedOwners: [(name: String, pid: Int, seconds: UInt64, microseconds: UInt64)] = [
            ("pid", 0, 100, 1),
            ("start-seconds", 46_001, 0, 1),
            ("start-usec", 46_001, 100, 1_000_000),
        ]
        let canonical = UUID(uuidString: runtimeUUID)!.uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())

        for malformed in malformedOwners {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "SimulatorLedgerBadOwner-\(malformed.name)-\(UUID().uuidString)",
                isDirectory: true
            )
            let fileURL = directory.appendingPathComponent("ledger.json")
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let payload: [String: Any] = [
                "schemaVersion": 4,
                "records": [
                    canonical: [
                        "identifier": canonical,
                        "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                        "attemptID": UUID().uuidString,
                        "owner": [
                            "pid": malformed.pid,
                            "startTimeSeconds": malformed.seconds,
                            "startTimeMicroseconds": malformed.microseconds,
                        ],
                        "reviewIdentity": [
                            "sessionID": reviewSessionID.uuidString,
                            "revision": 7,
                        ],
                        "phase": "reserved",
                        "reservedAt": now,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

            let ledger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
            XCTAssertEqual(
                ledger.observation(identifier: secondRuntimeUUID, kind: .simulatorRuntime),
                SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil),
                "\(malformed.name): a bad sibling record must invalidate the whole envelope"
            )
            XCTAssertEqual(
                ledger.reserve(
                    identifier: secondRuntimeUUID,
                    kind: .simulatorRuntime,
                    reviewIdentity: reviewIdentity
                ),
                .persistenceFailed,
                "\(malformed.name): corrupt owner evidence must not reopen submission"
            )

            let providerURL = directory.appendingPathComponent("provider.json")
            let malformedProvider = SimulatorLedgerProcessIdentity(
                pid: Int32(malformed.pid),
                startTimeSeconds: malformed.seconds,
                startTimeMicroseconds: malformed.microseconds
            )
            let providerLedger = PersistentSimulatorManagedOperationLedger(
                fileURL: providerURL,
                processIdentityProvider: { malformedProvider },
                processLivenessProbe: { _ in .active }
            )
            XCTAssertEqual(
                providerLedger.reserve(
                    identifier: runtimeUUID,
                    kind: .simulatorRuntime,
                    reviewIdentity: reviewIdentity
                ),
                .persistenceFailed,
                "\(malformed.name): a malformed current owner must not be persisted"
            )
        }
    }

    /// **v2026.07.16 schema-4 回归**：v3 attempt CAS 必须原样保留；死亡 owner 的 reserved
    /// 用私有 legacy review session 恢复，因此不会因升级永久锁死。与此同时 v3 submitted
    /// 仍保持 fail closed。第一次合法写事务会把 envelope 与新 reservation 持久化为 v4。
    func test_persistentLedger_schemaV3迁移保留attempt并写入reviewIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerV3-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reservedCanonical = UUID(uuidString: runtimeUUID)!.uuidString.lowercased()
        let submittedCanonical = UUID(uuidString: secondRuntimeUUID)!.uuidString.lowercased()
        let reservedAttemptID = UUID()
        let submittedAttemptID = UUID()
        let oldOwner = SimulatorLedgerProcessIdentity(
            pid: 47_001,
            startTimeSeconds: 100,
            startTimeMicroseconds: 1
        )
        let newOwner = SimulatorLedgerProcessIdentity(
            pid: 47_002,
            startTimeSeconds: 200,
            startTimeMicroseconds: 2
        )
        let now = ISO8601DateFormatter().string(from: Date())
        let ownerPayload: [String: Any] = [
            "pid": oldOwner.pid,
            "startTimeSeconds": oldOwner.startTimeSeconds,
            "startTimeMicroseconds": oldOwner.startTimeMicroseconds,
        ]
        let payload: [String: Any] = [
            "schemaVersion": 3,
            "records": [
                reservedCanonical: [
                    "identifier": reservedCanonical,
                    "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                    "attemptID": reservedAttemptID.uuidString,
                    "owner": ownerPayload,
                    "phase": "reserved",
                    "reservedAt": now,
                ],
                submittedCanonical: [
                    "identifier": submittedCanonical,
                    "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                    "attemptID": submittedAttemptID.uuidString,
                    "owner": ownerPayload,
                    "phase": "submitted",
                    "reservedAt": now,
                    "submittedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

        let migrated = PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { newOwner },
            processLivenessProbe: { $0 == oldOwner ? .inactive : .active }
        )
        XCTAssertEqual(
            migrated.observation(identifier: runtimeUUID, kind: .simulatorRuntime),
            SimulatorManagedLedgerObservation(
                state: .staleReservation,
                attemptID: reservedAttemptID
            )
        )
        XCTAssertEqual(
            migrated.observation(identifier: secondRuntimeUUID, kind: .simulatorRuntime),
            SimulatorManagedLedgerObservation(state: .submitted, attemptID: submittedAttemptID)
        )
        XCTAssertFalse(migrated.clearStaleReservationForFreshReview(
            identifier: secondRuntimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: submittedAttemptID,
            candidateReviewIdentity: reviewIdentity
        ), "legacy submitted cannot be downgraded to a recoverable reservation")
        XCTAssertTrue(migrated.clearStaleReservationForFreshReview(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            expectedAttemptID: reservedAttemptID,
            candidateReviewIdentity: reviewIdentity
        ))
        guard case .reserved = migrated.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else {
            return XCTFail("a proven-dead v3 reservation must not stay locked after a new review")
        }

        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        XCTAssertEqual((persistedObject["schemaVersion"] as? NSNumber)?.intValue, 4)
        let records = try XCTUnwrap(persistedObject["records"] as? [String: Any])
        let currentRecord = try XCTUnwrap(records[reservedCanonical] as? [String: Any])
        let persistedReview = try XCTUnwrap(currentRecord["reviewIdentity"] as? [String: Any])
        XCTAssertEqual(
            UUID(uuidString: try XCTUnwrap(persistedReview["sessionID"] as? String)),
            reviewIdentity.sessionID
        )
        XCTAssertEqual(
            (persistedReview["revision"] as? NSNumber)?.uint64Value,
            reviewIdentity.revision
        )
        XCTAssertEqual(
            migrated.observation(identifier: secondRuntimeUUID, kind: .simulatorRuntime),
            SimulatorManagedLedgerObservation(state: .submitted, attemptID: submittedAttemptID)
        )
    }

    /// A corrupt/non-canonical dictionary key must invalidate the entire ledger. Treating the
    /// canonical lookup as absent would permit a second record for an operation that may already
    /// have crossed Process.run.
    func test_persistentLedger_noncanonicalEnvelopeKey整体failClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorLedgerBadKey-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("ledger.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = UUID(uuidString: runtimeUUID)!.uuidString.lowercased()
        let now = ISO8601DateFormatter().string(from: Date())
        let payload: [String: Any] = [
            "schemaVersion": 3,
            "records": [
                canonical.uppercased(): [
                    "identifier": canonical,
                    "kind": ManagedUninstallRecipe.simulatorRuntime.rawValue,
                    "attemptID": UUID().uuidString,
                    "owner": [
                        "pid": 44_001,
                        "startTimeSeconds": 100,
                        "startTimeMicroseconds": 1,
                    ],
                    "phase": "submitted",
                    "reservedAt": now,
                    "submittedAt": now,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: fileURL, options: .atomic)

        let ledger = PersistentSimulatorManagedOperationLedger(fileURL: fileURL)
        XCTAssertEqual(
            ledger.observation(identifier: runtimeUUID, kind: .simulatorRuntime),
            SimulatorManagedLedgerObservation(state: .unavailable, attemptID: nil)
        )
        XCTAssertEqual(
            ledger.reserve(
                identifier: runtimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .persistenceFailed,
            "malformed existing records must never be bypassed as an absent canonical key"
        )
    }

    /// v2026.07.18 P1 regression: malformed/oversized managed-operation authority can never be
    /// interpreted as an empty first run or overwritten while minting a new Process.run permit.
    func test_persistentLedger_oversizedReadFailsClosedAndPreservesExistingBytes() throws {
        let fixture = try makeBoundedLedgerFixture("Oversized")
        let existing = Data(repeating: 0x4D, count: 129)
        try existing.write(to: fixture.fileURL)
        let ledger = makeBoundedLedger(
            fileURL: fixture.fileURL,
            storageLimits: .init(maximumBytes: 128, maximumRecordCount: 10)
        )

        XCTAssertEqual(
            ledger.observation(identifier: runtimeUUID, kind: .simulatorRuntime),
            .init(state: .unavailable, attemptID: nil)
        )
        XCTAssertEqual(
            ledger.reserve(
                identifier: runtimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .persistenceFailed
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), existing)
    }

    func test_persistentLedger_symlinkReadFailsClosedAndPreservesDestination() throws {
        let fixture = try makeBoundedLedgerFixture("Symlink")
        let destination = fixture.directory.appendingPathComponent("destination.json")
        let existing = Data("do-not-replace".utf8)
        try existing.write(to: destination)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL,
            withDestinationURL: destination
        )
        let ledger = makeBoundedLedger(fileURL: fixture.fileURL)

        XCTAssertEqual(
            ledger.observation(identifier: runtimeUUID, kind: .simulatorRuntime),
            .init(state: .unavailable, attemptID: nil)
        )
        XCTAssertEqual(
            ledger.reserve(
                identifier: runtimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .persistenceFailed
        )
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    /// A replacement or deletion found after initial metadata is never equivalent to the sole
    /// empty-ledger case (`initialPath + ENOENT`). Both races preserve the prior authority bytes.
    func test_persistentLedger_readReplacementAndFinalDeletionFailClosed() throws {
        let fixture = try makeBoundedLedgerFixture("ReadRace")
        let owner = makeBoundedLedger(fileURL: fixture.fileURL)
        guard case .reserved = owner.reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.fileURL)

        let scriptedErrors: [BoundedLocalFileReadError] = [
            .changed,
            .metadataUnavailable(stage: .finalPath, posixErrorCode: ENOENT),
        ]
        for error in scriptedErrors {
            let ledger = makeBoundedLedger(
                fileURL: fixture.fileURL,
                boundedReader: { _, _ in throw error }
            )
            XCTAssertEqual(
                ledger.observation(identifier: secondRuntimeUUID, kind: .simulatorRuntime),
                .init(state: .unavailable, attemptID: nil)
            )
            XCTAssertEqual(
                ledger.reserve(
                    identifier: secondRuntimeUUID,
                    kind: .simulatorRuntime,
                    reviewIdentity: reviewIdentity
                ),
                .persistenceFailed
            )
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), existing)
        }
    }

    func test_persistentLedger_recordCountWriteLimitPreservesExistingLedger() throws {
        let fixture = try makeBoundedLedgerFixture("RecordLimit")
        guard case .reserved = makeBoundedLedger(fileURL: fixture.fileURL).reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.fileURL)
        let ledger = makeBoundedLedger(
            fileURL: fixture.fileURL,
            storageLimits: .init(
                maximumBytes: PersistentSimulatorManagedOperationLedger.StorageLimits
                    .production.maximumBytes,
                maximumRecordCount: 1
            )
        )

        XCTAssertEqual(
            ledger.reserve(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .persistenceFailed
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), existing)
    }

    func test_persistentLedger_encodedByteWriteLimitPreservesExistingLedger() throws {
        let fixture = try makeBoundedLedgerFixture("EncodedByteLimit")
        guard case .reserved = makeBoundedLedger(fileURL: fixture.fileURL).reserve(
            identifier: runtimeUUID,
            kind: .simulatorRuntime,
            reviewIdentity: reviewIdentity
        ) else { return XCTFail("Fixture ledger must be created") }
        let existing = try Data(contentsOf: fixture.fileURL)
        let ledger = makeBoundedLedger(
            fileURL: fixture.fileURL,
            storageLimits: .init(maximumBytes: existing.count, maximumRecordCount: 2)
        )

        XCTAssertEqual(
            ledger.reserve(
                identifier: secondRuntimeUUID,
                kind: .simulatorRuntime,
                reviewIdentity: reviewIdentity
            ),
            .persistenceFailed
        )
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), existing)
    }

    private func makeBoundedLedgerFixture(
        _ label: String
    ) throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SimulatorLedger\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, directory.appendingPathComponent("ledger.json"))
    }

    private func makeBoundedLedger(
        fileURL: URL,
        storageLimits: PersistentSimulatorManagedOperationLedger.StorageLimits = .production,
        boundedReader: @escaping PersistentSimulatorManagedOperationLedger.BoundedReader = {
            url,
            maximumBytes in
            try BoundedLocalFileReader.read(at: url, maximumBytes: maximumBytes)
        }
    ) -> PersistentSimulatorManagedOperationLedger {
        let process = Self.boundedLedgerProcess
        return PersistentSimulatorManagedOperationLedger(
            fileURL: fileURL,
            processIdentityProvider: { process },
            processLivenessProbe: { $0 == process ? .active : .inactive },
            storageLimits: storageLimits,
            boundedReader: boundedReader
        )
    }

    private var deviceCardID: String { "card.test.simulator-devices" }
    private var runtimeCardID: String { "card.test.simulator-runtimes" }
    private var filesystemCardID: String { "card.test.filesystem" }

    private func deviceCard() -> DeveloperCard {
        managedCard(id: deviceCardID, kind: .simulatorDevice)
    }

    private func runtimeCard() -> DeveloperCard {
        managedCard(id: runtimeCardID, kind: .simulatorRuntime)
    }

    private func managedCard(id: String, kind: ManagedUninstallRecipe) -> DeveloperCard {
        DeveloperCard(
            id: id,
            title: id,
            summary: "test",
            source: .dynamicScanner(scannerID: "scanner.test.\(kind.rawValue)"),
            recipe: .managedUninstall(kind),
            risk: .confirm
        )
    }

    private func filesystemCard() -> DeveloperCard {
        DeveloperCard(
            id: filesystemCardID,
            title: filesystemCardID,
            summary: "test",
            source: .literal(paths: []),
            recipe: .filesystem,
            risk: .safe
        )
    }

    private func hit(name: String,
                     path: String,
                     sizeBytes: Int64? = nil,
                     identifier: String?) -> WorkflowScanHit {
        WorkflowScanHit(
            url: URL(fileURLWithPath: path),
            sizeBytes: sizeBytes,
            displayName: name,
            note: nil,
            managedUninstallIdentifier: identifier
        )
    }

    private func makeItem(hitID: String,
                          name: String,
                          kind: ManagedUninstallRecipe,
                          identifier: String) -> SimulatorDeleteCoordinator.Item {
        SimulatorDeleteCoordinator.Item(
            cardID: kind == .simulatorRuntime ? runtimeCardID : deviceCardID,
            hitID: hitID,
            displayName: name,
            kind: kind,
            sizeBytes: 1_024,
            executable: kind.executable,
            args: kind.argsPrefix + [identifier]
        )
    }

    private func makeCoordinator(
        running: Bool = false,
        allowlist: [SubprocessExecutor.AllowEntry] = SubprocessExecutor.defaultAllowlist
    ) -> SimulatorDeleteCoordinator {
        SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: allowlist,
                timeout: 1,
                dryRun: true
            ),
            isSimulatorRunning: { running },
            bootedDeviceProbe: { .safeToSubmit }
        )
    }

    private func assertStarted(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .started(actualIndex, actualTotal, item) = event else {
            return XCTFail("Expected a started event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(item.hitID, hitID, file: file, line: line)
    }

    private func assertSubmitted(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .submitted(actualIndex, actualTotal, item) = event else {
            return XCTFail("Expected a submitted event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(item.hitID, hitID, file: file, line: line)
    }

    private func assertRunning(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .running(actualIndex, actualTotal, item) = event else {
            return XCTFail("Expected a running event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(item.hitID, hitID, file: file, line: line)
    }

    private func assertBlockedSimulatorRunning(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .blockedSimulatorRunning(actualIndex, actualTotal, item) = event else {
            return XCTFail("Expected a blockedSimulatorRunning event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(item.hitID, hitID, file: file, line: line)
    }

    private func assertStalled(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .stalled(actualIndex, actualTotal, item, elapsed) = event else {
            return XCTFail("Expected a stalled event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(item.hitID, hitID, file: file, line: line)
        XCTAssertGreaterThan(elapsed, 0, file: file, line: line)
    }

    private func assertFinished(
        _ event: SimulatorDeleteCoordinator.ExecutionEvent,
        index: Int,
        total: Int,
        hitID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .finished(actualIndex, actualTotal, outcome) = event else {
            return XCTFail("Expected a finished event", file: file, line: line)
        }
        XCTAssertEqual(actualIndex, index, file: file, line: line)
        XCTAssertEqual(actualTotal, total, file: file, line: line)
        XCTAssertEqual(outcome.item.hitID, hitID, file: file, line: line)
        XCTAssertTrue(outcome.isSuccess, file: file, line: line)
    }
}

@MainActor
final class WorkflowManagedUninstallViewModelTests: XCTestCase {
    private let deviceUUID = "11111111-2222-3333-4444-555555555555"
    private let runtimeUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    func test_mixedVisualSelection_routesManagedItemsWithoutJoiningTrashItems() async {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let filesystemCard = makeFilesystemCard()
        let deviceCard = makeManagedCard(id: "card.vm.device", kind: .simulatorDevice)
        let runtimeCard = makeManagedCard(id: "card.vm.runtime", kind: .simulatorRuntime)
        let filesystemHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-filesystem"),
            sizeBytes: 10,
            displayName: "Cache",
            note: nil
        )
        let deviceHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-device"),
            sizeBytes: 20,
            displayName: "iPhone 17",
            note: nil,
            managedUninstallIdentifier: deviceUUID
        )
        let runtimeHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-runtime"),
            sizeBytes: 30,
            displayName: "iOS 26.2",
            note: nil,
            managedUninstallIdentifier: runtimeUUID
        )
        let viewModel = makeViewModel(home: home)
        viewModel.setTestCards([filesystemCard, deviceCard, runtimeCard])
        viewModel.setTestHits([
            filesystemCard.id: [filesystemHit],
            deviceCard.id: [deviceHit],
            runtimeCard.id: [runtimeHit],
        ])
        viewModel.setTestSelection([filesystemHit.id, deviceHit.id, runtimeHit.id])

        XCTAssertEqual(viewModel.selectedFilesystemCount, 1)
        XCTAssertEqual(viewModel.selectedManagedUninstallCount, 2)

        await viewModel.requestSimulatorUninstall()

        guard case let .review(intent) = viewModel.simulatorUninstallState else {
            return XCTFail("Managed uninstall must enter its own review state")
        }
        XCTAssertEqual(intent.selectedHitIDs, [deviceHit.id, runtimeHit.id])
        XCTAssertEqual(intent.items.map(\.kind), [.simulatorDevice, .simulatorRuntime])
        XCTAssertEqual(intent.totalBytes, 50)
        XCTAssertTrue(viewModel.selected.contains(filesystemHit.id))
        guard case .simulatorUninstall = viewModel.activeSheet else {
            return XCTFail("Managed uninstall must not reuse the Trash confirmation route")
        }
    }

    func test_nonDeletableManagedHit_isNotSelectableOrSubmitted() async {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runtimeCard = makeManagedCard(id: "card.vm.runtime", kind: .simulatorRuntime)
        let runtimeHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-runtime-legacy"),
            sizeBytes: 30,
            displayName: "Legacy iOS Runtime",
            note: nil,
            managedUninstallIdentifier: nil
        )
        let viewModel = makeViewModel(home: home)
        viewModel.setTestCards([runtimeCard])
        viewModel.setTestHits([runtimeCard.id: [runtimeHit]])

        XCTAssertFalse(viewModel.canSelect(card: runtimeCard, hit: runtimeHit))
        XCTAssertEqual(viewModel.selectedManagedUninstallCount, 0)
        await viewModel.requestSimulatorUninstall()
        XCTAssertNil(viewModel.simulatorUninstallState)
        XCTAssertNil(viewModel.activeSheet)
    }

    func test_reviewedManagedUninstall_executesAndRemovesOnlySuccessfulManagedRows() async {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let filesystemCard = makeFilesystemCard()
        let runtimeCard = makeManagedCard(id: "card.vm.runtime", kind: .simulatorRuntime)
        let filesystemHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-retained-filesystem"),
            sizeBytes: 10,
            displayName: "Retained Cache",
            note: nil
        )
        let runtimeHit = WorkflowScanHit(
            url: URL(fileURLWithPath: "/tmp/vm-runtime-success"),
            sizeBytes: 30,
            displayName: "iOS 26.2",
            note: nil,
            managedUninstallIdentifier: runtimeUUID
        )
        let viewModel = makeViewModel(home: home)
        viewModel.setTestCards([filesystemCard, runtimeCard])
        viewModel.setTestHits([
            filesystemCard.id: [filesystemHit],
            runtimeCard.id: [runtimeHit],
        ])
        viewModel.setTestSelection([filesystemHit.id, runtimeHit.id])

        await viewModel.requestSimulatorUninstall()
        await viewModel.executeSimulatorUninstall()

        guard case let .finished(intent, completion) = viewModel.simulatorUninstallState else {
            return XCTFail("A submitted managed operation must reach an explicit terminal state")
        }
        XCTAssertEqual(intent.items.map(\.hitID), [runtimeHit.id])
        XCTAssertEqual(completion.succeededCount, 1)
        XCTAssertEqual(completion.receipt?.submittedItemIDs, [runtimeHit.id])
        XCTAssertEqual(viewModel.cardHits[filesystemCard.id], [filesystemHit])
        XCTAssertEqual(viewModel.cardHits[runtimeCard.id], [])
        XCTAssertEqual(viewModel.selected, [filesystemHit.id])
        XCTAssertTrue(viewModel.cardLoading.isEmpty)
    }

    private func makeTemporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowManagedUninstallTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeViewModel(home: URL) -> WorkflowDetailViewModel {
        WorkflowDetailViewModel(
            workflow: EmptyWorkflow(),
            home: home,
            simulatorCoordinator: SimulatorDeleteCoordinator(
                executor: SubprocessExecutor(timeout: 1, dryRun: true),
                isSimulatorRunning: { false },
                bootedDeviceProbe: { .safeToSubmit }
            ),
            // v2026.07.20: even a managed-only ViewModel test must not inherit production Undo;
            // future fixture changes may add filesystem moved pairs to the same model.
            undoHistoryStore: UndoHistoryStore(
                storeURL: home.appendingPathComponent(
                    ".SimulatorDeleteCoordinatorTests-\(UUID().uuidString)-UndoHistory.json"
                ),
                allowedRestoreRoots: [home.path]
            )
        )
    }

    private func makeFilesystemCard() -> DeveloperCard {
        DeveloperCard(
            id: "card.vm.filesystem",
            title: "Filesystem",
            summary: "test",
            source: .literal(paths: []),
            recipe: .filesystem,
            risk: .safe
        )
    }

    private func makeManagedCard(id: String, kind: ManagedUninstallRecipe) -> DeveloperCard {
        DeveloperCard(
            id: id,
            title: id,
            summary: "test",
            source: .dynamicScanner(scannerID: "scanner.test.\(kind.rawValue)"),
            recipe: .managedUninstall(kind),
            risk: .confirm
        )
    }
}

private actor ManagedEventRecorder {
    private var events: [SimulatorDeleteCoordinator.ExecutionEvent] = []

    func append(_ event: SimulatorDeleteCoordinator.ExecutionEvent) {
        events.append(event)
    }

    func snapshot() -> [SimulatorDeleteCoordinator.ExecutionEvent] {
        events
    }
}

/// 同步 `@Sendable` probe 的确定性序列。NSLock 仅用于测试注入状态，不进入产品代码。
private final class LockedRunningSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return false }
        return values.removeFirst()
    }
}

/// 把权威查询与 GUI 运行态变化放在同一个锁保护的测试探针中，
/// 确定性重现“Booted 查询期间 Simulator.app 启动”，不依赖 sleep/timing。
private final class LockedSubmissionOrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var simulatorRunning = false
    private var calls: [String] = []

    func queryBootedDevicesAndStartSimulator() -> SimctlBootedDeviceProbe.ProbeResult {
        lock.lock()
        defer { lock.unlock() }
        calls.append("booted")
        simulatorRunning = true
        return .safeToSubmit
    }

    func isSimulatorRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls.append("simulator")
        return simulatorRunning
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct EmptyWorkflow: DeveloperWorkflow {
    let id = "workflow.test.empty"
    let displayName = "Test"
    let subtitle = "Test"

    func cards(home: URL) -> [DeveloperCard] { [] }
}
