import XCTest
@testable import ScanKit

final class FileAllocationSnapshotTests: XCTestCase {
    private func catalog(_ observations: [(String, UInt64, Int64)]) -> FileAllocationSnapshot {
        let ledger = InodeSet(tracksPaths: true)
        for (path, inode, bytes) in observations {
            let first = ledger.insertIfFirstSeen(device: 1, inode: inode, path: path,
                                                 allocatedBytes: bytes, logicalBytes: bytes, linkCount: 2)
            ledger.recordDirectory(path: (path as NSString).deletingLastPathComponent,
                allocatedBytes: first ? bytes : 0, logicalBytes: first ? bytes : 0, fileCount: 1)
        }
        return ledger.allocationSnapshot()
    }

    func testRefreshPreservesGlobalOwnerAndTransfersAllocationWhenOwnerDisappears() {
        let original = catalog([("/A/file", 10, 4096), ("/B/link", 10, 4096)])
        let unchanged = original.replacing(with: catalog([("/B/link", 10, 4096)]),
                                            replacesPath: { $0 == "/B" || $0.hasPrefix("/B/") })
        XCTAssertEqual(unchanged.incomingDeltas.first?.allocatedBytes, -4096)
        XCTAssertTrue(unchanged.externalDeltas.isEmpty)
        XCTAssertEqual(unchanged.snapshot.aggregate(inDirectory: "/B").allocatedBytes, 0)
        XCTAssertEqual(unchanged.snapshot.aggregate(inDirectory: "/").fileCount, 2)

        let removed = unchanged.snapshot.replacing(with: .init(), replacesPath: { $0 == "/A" || $0.hasPrefix("/A/") })
        XCTAssertEqual(removed.externalDeltas.first?.path, "/B/link")
        XCTAssertEqual(removed.externalDeltas.first?.allocatedBytes, 4096)
        XCTAssertEqual(removed.snapshot.aggregate(inDirectory: "/").allocatedBytes, 4096)
        XCTAssertEqual(removed.snapshot.aggregate(inDirectory: "/").fileCount, 1)
    }

    func testNewAliasOfKnownLinkedIdentityAndContentChangesRemainOneAllocation() {
        // Only one path was initially inside the scan domain; the inode was already linked.
        let original = catalog([("/A/file", 10, 4096)])
        let linked = original.replacing(with: catalog([("/B/new-link", 10, 8192)]),
                                         replacesPath: { $0 == "/B" || $0.hasPrefix("/B/") })
        XCTAssertEqual(linked.incomingDeltas.first?.allocatedBytes, -8192)
        XCTAssertEqual(linked.externalDeltas.first?.path, "/A/file")
        XCTAssertEqual(linked.externalDeltas.first?.allocatedBytes, 4096)
        XCTAssertEqual(linked.snapshot.aggregate(inDirectory: "/").allocatedBytes, 8192)
        XCTAssertEqual(linked.snapshot.aggregate(inDirectory: "/").fileCount, 2)
    }

    func testOrdinaryFileNamesAreNotRetainedAfterFreezingDirectoryTotals() {
        let ledger = InodeSet(tracksPaths: true)
        for inode in 1...10_000 {
            XCTAssertTrue(ledger.insertIfFirstSeen(device: 1, inode: UInt64(inode),
                path: "/A/file-\(inode)", allocatedBytes: 4096, logicalBytes: 4096, linkCount: 1))
        }
        ledger.recordDirectory(path: "/A", allocatedBytes: 40_960_000, logicalBytes: 40_960_000, fileCount: 10_000)
        let frozen = ledger.allocationSnapshot()
        XCTAssertEqual(frozen.retainedLinkedIdentityCount, 0)
        XCTAssertEqual(frozen.retainedDirectoryCount, 1)
        XCTAssertEqual(frozen.aggregate(inDirectory: "/A").fileCount, 10_000)
        XCTAssertEqual(frozen.aggregate(inDirectory: "/A").allocatedBytes, 40_960_000)
    }
}
