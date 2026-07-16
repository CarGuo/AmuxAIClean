import XCTest
@testable import AppUI

/// v2026.07.16: deterministic state-machine tests use suspended loaders only. They never scan
/// real ports and never submit a process termination request.
@MainActor
final class PortCleanerReloadModelTests: XCTestCase {
    func test_旧reload晚到不能覆盖新revision的可信快照() async {
        let probe = PortReloadProbe()
        let model = PortCleanerReloadModel { await probe.load() }

        model.reload()
        let firstPending = await waitUntil { await probe.isPending(call: 1) }
        XCTAssertTrue(firstPending)
        model.reload()
        let secondPending = await waitUntil { await probe.isPending(call: 2) }
        XCTAssertTrue(secondPending)

        await probe.resume(call: 2, with: .success(entries: [entry(port: 4002)]))
        let newSnapshotApplied = await waitUntil { model.entries.map(\.localPort) == [4002] }
        XCTAssertTrue(newSnapshotApplied)
        await probe.resume(call: 1, with: .success(entries: [entry(port: 4001)]))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(model.entries.map(\.localPort), [4002])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.failure)
    }

    func test_reload失败保留上次可信entries并只保存typedFailure() async {
        let probe = PortReloadProbe()
        let model = PortCleanerReloadModel { await probe.load() }

        model.reload()
        let initialPending = await waitUntil { await probe.isPending(call: 1) }
        XCTAssertTrue(initialPending)
        await probe.resume(call: 1, with: .success(entries: [entry(port: 5001)]))
        let trustedSnapshotApplied = await waitUntil { model.entries.map(\.localPort) == [5001] }
        XCTAssertTrue(trustedSnapshotApplied)

        model.reload()
        let failedReloadPending = await waitUntil { await probe.isPending(call: 2) }
        XCTAssertTrue(failedReloadPending)
        await probe.resume(
            call: 2,
            with: .failure(.outputTruncated(command: .lsof))
        )
        let failureApplied = await waitUntil { model.failure != nil }
        XCTAssertTrue(failureApplied)

        XCTAssertEqual(model.entries.map(\.localPort), [5001])
        XCTAssertEqual(model.failure, .outputTruncated(command: .lsof))
        XCTAssertFalse(model.isLoading)
    }

    func test_cancel旋转revision_不应用取消后才返回的结果() async {
        let probe = PortReloadProbe()
        let model = PortCleanerReloadModel { await probe.load() }

        model.reload()
        let pending = await waitUntil { await probe.isPending(call: 1) }
        XCTAssertTrue(pending)
        model.cancel()
        XCTAssertFalse(model.isLoading)

        await probe.resume(call: 1, with: .success(entries: [entry(port: 6001)]))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isLoading)
    }

    private func entry(port: Int) -> PortCleanerEntry {
        PortCleanerEntry(
            proto: .tcp,
            localAddress: "127.0.0.1",
            localPort: port,
            pid: Int32(port),
            processName: "fixture"
        )
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }
}

private actor PortReloadProbe {
    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<PortCleanerScanOutcome, Never>] = [:]

    func load() async -> PortCleanerScanOutcome {
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func isPending(call: Int) -> Bool {
        continuations[call] != nil
    }

    func resume(call: Int, with outcome: PortCleanerScanOutcome) {
        continuations.removeValue(forKey: call)?.resume(returning: outcome)
    }
}
