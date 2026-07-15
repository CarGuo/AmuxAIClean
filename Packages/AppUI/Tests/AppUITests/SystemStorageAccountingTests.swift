import XCTest
import SafetyKit
@testable import AppUI

@MainActor
final class SystemStorageAccountingTests: XCTestCase {
    func testTopLevelAndOnDemandTreeUseAllocatedSizeForSparseFile() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GSYCleanMac-SystemStorage-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Docker", isDirectory: true)
        let sparse = nested.appendingPathComponent("Docker.raw")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: Data([0x1])))
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try handle.close()
        defer { removeFixture(root) }

        let coordinator = ScanCoordinator()
        coordinator.scan(
            category: ScanCategory(
                id: "test.system-storage.sparse",
                title: "test",
                subtitle: "test",
                rootPath: root.path,
                defaultVerdict: .confirm
            )
        )
        try await waitUntilScanStops(coordinator)
        XCTAssertTrue(coordinator.snapshot.isFinished)

        let topLevelRow = try XCTUnwrap(
            coordinator.snapshot.rows.first(where: { $0.url.path == nested.path })
        )
        XCTAssertLessThan(
            topLevelRow.bytes,
            64 * 1_024 * 1_024,
            "顶层清理主值必须使用系统储存占用，不能把 sparse 虚拟容量当成可释放空间"
        )
        XCTAssertGreaterThan(
            topLevelRow.logicalBytes,
            1 * 1_024 * 1_024 * 1_024,
            "Finder 式详情仍应保留 sparse 文件的逻辑容量"
        )

        let rows = await coordinator.directChildrenAsync(of: nested.path, sortedBy: .sizeDesc)
        let dockerRow = try XCTUnwrap(rows.first(where: { $0.path == sparse.path }))
        XCTAssertLessThan(
            dockerRow.bytes,
            64 * 1_024 * 1_024,
            "按需展开必须和顶层使用同一个 allocated-size 口径"
        )
    }

    private func waitUntilScanStops(_ coordinator: ScanCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while coordinator.isScanning {
            if Date() >= deadline {
                coordinator.cancel()
                XCTFail("测试扫描 5 秒内未结束")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func removeFixture(_ url: URL,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("清理 sparse fixture 失败：\(error)", file: file, line: line)
        }
    }
}
