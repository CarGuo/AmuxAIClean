import Darwin
import XCTest
import ScanKit
@testable import AppUI

final class DuplicateHandlingPlanTests: XCTestCase {
    private func identity(inode: UInt64, logicalBytes: Int64) -> DuplicateFileIdentity {
        DuplicateFileIdentity(
            device: 1,
            inode: inode,
            fileType: UInt16(S_IFREG),
            logicalBytes: logicalBytes,
            modificationSeconds: 1,
            modificationNanoseconds: 0,
            statusChangeSeconds: 1,
            statusChangeNanoseconds: 0
        )
    }

    private func makeGroup() -> DuplicateGroup {
        let fingerprint = DuplicateContentFingerprint(
            sha256Hex: String(repeating: "a", count: 64),
            logicalBytes: 100
        )!
        // v2026.07.17: This helper returns the frozen full-content fixture consumed by every
        // handling-plan assertion; constructing and discarding it left the suite uncompilable.
        return DuplicateGroup(
            hashKey: "g",
            logicalBytes: 100,
            files: [
                DuplicateFile(path: "/a", allocatedBytes: 80, snapshotIdentity: identity(inode: 1, logicalBytes: 100)),
                DuplicateFile(path: "/b", allocatedBytes: 40, snapshotIdentity: identity(inode: 2, logicalBytes: 100)),
                DuplicateFile(path: "/c", allocatedBytes: 20, snapshotIdentity: identity(inode: 3, logicalBytes: 100))
            ],
            reliability: .full,
            contentFingerprint: fingerprint
        )
    }

    func test_defaultDeleteTargets_keepsFirstCopy() {
        let group = makeGroup()

        XCTAssertEqual(DuplicateHandlingPlan.defaultDeleteTargets(for: group), ["/b", "/c"])
        XCTAssertEqual(group.reclaimableBytes, 60,
                       "默认可释放必须精确对应默认删除路径的 allocated bytes")
    }

    func test_prefixOnly只能复核不能生成删除目标() {
        let group = DuplicateGroup(
            hashKey: "prefix-only",
            logicalBytes: 512 * 1_024 * 1_024,
            files: [
                DuplicateFile(path: "/large-a", allocatedBytes: 100),
                DuplicateFile(path: "/large-b", allocatedBytes: 100)
            ],
            reliability: .prefixOnly
        )

        XCTAssertTrue(DuplicateHandlingPlan.defaultDeleteTargets(for: group).isEmpty)
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/large-b"], for: group),
                       "前 64KB 一致不能跨过删除证明边界")
    }

    func test_fullLabelWithoutTypedHashAndIdentityCannotGenerateDeleteTargets() {
        let group = DuplicateGroup(
            hashKey: "legacy-full-label",
            logicalBytes: 100,
            files: [
                DuplicateFile(path: "/a", allocatedBytes: 100),
                DuplicateFile(path: "/b", allocatedBytes: 100)
            ],
            reliability: .full
        )

        XCTAssertFalse(DuplicateHandlingPlan.isExecutableGroup(group))
        XCTAssertTrue(DuplicateHandlingPlan.defaultDeleteTargets(for: group).isEmpty)
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/b"], for: group))
    }

    func test_isValidDeleteTargets_requiresAtLeastOneRemainingCopy() {
        let group = makeGroup()

        XCTAssertTrue(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets([], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/a", "/b", "/c"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/b", "/b"], for: group))
        XCTAssertFalse(DuplicateHandlingPlan.isValidDeleteTargets(["/outside"], for: group))
    }

    func test_manualSelectionUsesPerPathAllocatedBytes() {
        let group = makeGroup()

        XCTAssertEqual(group.allocatedBytes(for: ["/a", "/c"]), 100)
        XCTAssertEqual(group.allocatedBytes(for: ["/outside"]), 0)
    }

    func test_pruningReusesUnaffectedGroupsAndRecomputesOnlyAffectedAllocatedTotals() {
        let affected = makeGroup()
        let unaffected = DuplicateGroup(
            hashKey: "other",
            logicalBytes: 200,
            files: [
                DuplicateFile(path: "/x", allocatedBytes: 70, snapshotIdentity: identity(inode: 4, logicalBytes: 200)),
                DuplicateFile(path: "/y", allocatedBytes: 30, snapshotIdentity: identity(inode: 5, logicalBytes: 200))
            ],
            reliability: .full,
            contentFingerprint: DuplicateContentFingerprint(
                sha256Hex: String(repeating: "b", count: 64),
                logicalBytes: 200
            )!
        )

        let result = DuplicateHandlingPlan.pruning(
            [affected, unaffected],
            movedPaths: ["/b"]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].paths, ["/a", "/c"])
        XCTAssertEqual(result[0].totalBytes, 100)
        XCTAssertEqual(result[0].reclaimableBytes, 20)
        XCTAssertEqual(result[1], unaffected)
    }

    func test_keepNewestDeleteTargets_retainsLatestMtimeCopy() {
        let fingerprint = DuplicateContentFingerprint(
            sha256Hex: String(repeating: "c", count: 64),
            logicalBytes: 100
        )!
        let oldIdentity = DuplicateFileIdentity(
            device: 1, inode: 10, fileType: UInt16(S_IFREG), logicalBytes: 100,
            modificationSeconds: 1_000, modificationNanoseconds: 0,
            statusChangeSeconds: 1_000, statusChangeNanoseconds: 0
        )
        let newestIdentity = DuplicateFileIdentity(
            device: 1, inode: 11, fileType: UInt16(S_IFREG), logicalBytes: 100,
            modificationSeconds: 2_000, modificationNanoseconds: 500,
            statusChangeSeconds: 2_000, statusChangeNanoseconds: 500
        )
        let midIdentity = DuplicateFileIdentity(
            device: 1, inode: 12, fileType: UInt16(S_IFREG), logicalBytes: 100,
            modificationSeconds: 2_000, modificationNanoseconds: 100,
            statusChangeSeconds: 2_000, statusChangeNanoseconds: 100
        )
        let group = DuplicateGroup(
            hashKey: "mtime-group",
            logicalBytes: 100,
            files: [
                DuplicateFile(path: "/dir/old.bin", allocatedBytes: 100, snapshotIdentity: oldIdentity),
                DuplicateFile(path: "/dir/newest.bin", allocatedBytes: 100, snapshotIdentity: newestIdentity),
                DuplicateFile(path: "/dir/mid.bin", allocatedBytes: 100, snapshotIdentity: midIdentity)
            ],
            reliability: .full,
            contentFingerprint: fingerprint
        )

        XCTAssertEqual(
            DuplicateHandlingPlan.keepNewestDeleteTargets(for: group),
            ["/dir/mid.bin", "/dir/old.bin"]
        )
    }
}
