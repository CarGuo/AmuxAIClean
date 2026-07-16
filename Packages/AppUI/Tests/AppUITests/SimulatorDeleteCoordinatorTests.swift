import XCTest
import Foundation
import ScanKit
@testable import AppUI

/// Simulator system-managed uninstall contract tests.
///
/// No test in this file starts a real `simctl` process. Execution tests inject a dry-run
/// `SubprocessExecutor`, while preparation tests exercise only pure typed-plan validation.
final class SimulatorDeleteCoordinatorTests: XCTestCase {
    private let deviceUUID = "11111111-2222-3333-4444-555555555555"
    private let runtimeUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let secondRuntimeUUID = "12345678-1234-1234-1234-123456789abc"

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
            stopControl: control
        ) { event in
            await recorder.append(event)
        }

        let events = await recorder.snapshot()
        XCTAssertEqual(events.count, 4)
        assertStarted(events[0], index: 1, total: 2, hitID: items[0].hitID)
        assertFinished(events[1], index: 1, total: 2, hitID: items[0].hitID)
        assertStarted(events[2], index: 2, total: 2, hitID: items[1].hitID)
        assertFinished(events[3], index: 2, total: 2, hitID: items[1].hitID)
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
        XCTAssertEqual(events.count, 2)
        assertStarted(events[0], index: 1, total: 3, hitID: items[0].hitID)
        assertFinished(events[1], index: 1, total: 3, hitID: items[0].hitID)
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
            argsPrefix: ["managed"]
        )
        let coordinator = SimulatorDeleteCoordinator(
            executor: SubprocessExecutor(
                allowlist: [allowEntry],
                terminalWaitPolicy: .waitUntilExit,
                dryRun: false
            ),
            isSimulatorRunning: { false }
        )
        let item = SimulatorDeleteCoordinator.Item(
            cardID: runtimeCardID,
            hitID: "/tmp/runtime-launch-failure",
            displayName: "Runtime launch failure",
            kind: .simulatorRuntime,
            executable: missingExecutable,
            args: ["managed"]
        )

        let completion = await coordinator.executeManaged(
            items: [item],
            stopControl: SimulatorDeleteCoordinator.StopControl()
        ) { _ in }

        XCTAssertEqual(completion.outcomes.first?.exitCode, -1)
        XCTAssertEqual(completion.outcomes.first?.wasSubmitted, false)
        XCTAssertNil(completion.receipt,
                     "Process.run 失败没有跨过提交边界，不能铸造 receipt")
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
            isSimulatorRunning: { running }
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
                isSimulatorRunning: { false }
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

private struct EmptyWorkflow: DeveloperWorkflow {
    let id = "workflow.test.empty"
    let displayName = "Test"
    let subtitle = "Test"

    func cards(home: URL) -> [DeveloperCard] { [] }
}
