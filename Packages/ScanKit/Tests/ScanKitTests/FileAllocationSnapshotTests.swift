import XCTest
@testable import ScanKit

final class FileAllocationSnapshotTests: XCTestCase {
    // v2026.10.09: the batch aggregate used by partial refresh must preserve directory
    // boundaries, empty directories and separate allocated/logical totals without file paths.
    func testDirectoryAggregatesShareOneScopedAllocationBaseline() {
        let ledger = InodeSet(tracksPaths: true)
        ledger.recordScanRoot(path: "/")
        ledger.recordDirectory(path: "/A", allocatedBytes: 4096, logicalBytes: 1000, fileCount: 1)
        ledger.recordDirectory(path: "/A/nested", allocatedBytes: 8192, logicalBytes: 6000, fileCount: 2)
        ledger.recordDirectory(path: "/A/empty", allocatedBytes: 0, logicalBytes: 0, fileCount: 0)
        ledger.recordDirectory(path: "/AB", allocatedBytes: 16384, logicalBytes: 12000, fileCount: 1)
        let catalog = ledger.allocationSnapshot()
        let values = catalog.directoryAggregates(inDirectory: "/A")
        XCTAssertEqual(Set(values.keys), ["/A", "/A/nested", "/A/empty"])
        XCTAssertEqual(values["/A"]?.allocatedBytes, catalog.aggregate(inDirectory: "/A").allocatedBytes)
        XCTAssertEqual(values["/A"]?.logicalBytes, 7000)
        XCTAssertEqual(values["/A"]?.fileCount, 3)
        XCTAssertEqual(values["/A/nested"]?.allocatedBytes, 8192)
        XCTAssertEqual(values["/A/empty"]?.fileCount, 0)
        XCTAssertEqual(catalog.directoryAggregates(inDirectory: "/")["/"]?.allocatedBytes, 28672)
    }

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
