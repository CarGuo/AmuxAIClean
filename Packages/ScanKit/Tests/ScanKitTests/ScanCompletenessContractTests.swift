import Darwin
import XCTest
@testable import ScanKit

final class ScanCompletenessContractTests: XCTestCase {
    private func makeTemporaryFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCompleteness-\(UUID().uuidString).bin")
        try Data(repeating: 0xA5, count: 128).write(to: file)
        return file
    }

    func test_bulkEnumerate_reportsStructuredFailureWhenRootIsNotDirectory() throws {
        let file = try makeTemporaryFile()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: file)) }

        let fd = Darwin.open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { XCTAssertEqual(Darwin.close(fd), 0) }

        var emittedEntryCount = 0
        let outcome = BulkEnumerate.enumerate(fd: fd, dirPath: file.path) { _ in
            emittedEntryCount += 1
            return true
        }

        guard case .failed(let issue) = outcome else {
            return XCTFail("非目录根应返回带诊断的 failed，实际=\(outcome)")
        }
        XCTAssertEqual(issue.path, file.path)
        XCTAssertEqual(issue.reason, .enumerationFailed)
        XCTAssertEqual(issue.stage, .enumerate)
        XCTAssertNotNil(issue.posixErrorCode)
        XCTAssertEqual(emittedEntryCount, 0)
    }

    func test_bulkScanner_failedEnumerationProducesPartialSummaryAndExactIssue() async throws {
        let file = try makeTemporaryFile()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: file)) }

        let expected = ScanIncompleteIssue(
            path: file.path,
            reason: .enumerationFailed,
            stage: .enumerate,
            posixErrorCode: ENOTDIR
        )
        var issues: [ScanIncompleteIssue] = []
        var failures: [ScanError] = []
        var summary: ScanSummary?

        for await event in BulkScanner().scan(root: file) {
            switch event {
            case .incomplete(let issue):
                issues.append(issue)
            case .failed(let failure):
                failures.append(failure)
            case .finished(let value):
                summary = value
            default:
                break
            }
        }

        XCTAssertEqual(issues, [expected])
        XCTAssertEqual(failures.count, 1)
        guard case .cannotEnumerate(let path, let stage, let posixErrorCode) = failures.first else {
            return XCTFail("非目录根必须产生结构化根级失败，实际=\(failures)")
        }
        XCTAssertEqual(path, file.path)
        XCTAssertEqual(stage, .enumerate)
        XCTAssertNotNil(posixErrorCode)
        XCTAssertEqual(summary?.completionStatus, .partial)
        XCTAssertEqual(summary?.incompleteIssues, [expected])
        XCTAssertEqual(summary?.permissionDeniedCount, 0)
    }

    func test_bulkScanner_missingRootIsEnumerationFailureNotPermissionDenial() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCompleteness-missing-\(UUID().uuidString)", isDirectory: true)
        let expected = ScanIncompleteIssue(
            path: missingRoot.path,
            reason: .enumerationFailed,
            stage: .open,
            posixErrorCode: ENOENT
        )
        var issues: [ScanIncompleteIssue] = []
        var permissionDeniedEventCount = 0
        var failures: [ScanError] = []
        var summary: ScanSummary?

        for await event in BulkScanner().scan(root: missingRoot) {
            switch event {
            case .incomplete(let issue):
                issues.append(issue)
            case .permissionDenied:
                permissionDeniedEventCount += 1
            case .failed(let failure):
                failures.append(failure)
            case .finished(let value):
                summary = value
            default:
                break
            }
        }

        XCTAssertEqual(issues, [expected])
        XCTAssertEqual(permissionDeniedEventCount, 0)
        XCTAssertEqual(failures, [
            .cannotEnumerate(
                path: missingRoot.path,
                stage: .open,
                posixErrorCode: ENOENT
            )
        ])
        XCTAssertEqual(summary?.permissionDeniedCount, 0)
        XCTAssertEqual(summary?.completionStatus, .partial)
        XCTAssertEqual(summary?.incompleteIssues, [expected])
    }

    /// 真实现场目录权限是 0644：目录可读但没有 execute/search bit。
    /// `open(O_RDONLY)` 可能成功，随后 getattrlistbulk/FileManager 才返回 EACCES。
    /// 这是后代目录的完整性缺口，不得把整轮根扫描升级成 `.failed`。
    func test_bulkScanner_descendantWithoutSearchPermissionIsPartialNotTerminalFailure() async throws {
        if getuid() == 0 {
            throw XCTSkip("root 不受目录 mode bit 限制")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanCompleteness-descendant-\(UUID().uuidString)", isDirectory: true)
        let denied = root.appendingPathComponent("readable-but-not-searchable", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data([0x01]).write(to: denied.appendingPathComponent("payload.bin"))
        XCTAssertEqual(chmod(denied.path, 0o400), 0)
        defer {
            _ = chmod(denied.path, 0o700)
            XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
        }

        var permissionDeniedPaths: [String] = []
        var issues: [ScanIncompleteIssue] = []
        var failures: [ScanError] = []
        var summary: ScanSummary?

        let scanner = BulkScanner(options: ScanOptions(
            includeHidden: true,
            includePackageContents: true,
            followSymlinks: false,
            followFirmlinks: false,
            dedupByInode: true,
            concurrency: 1,
            maxConcurrency: 1,
            staySingleVolume: true,
            mediaAware: false,
            respectTCCSkipList: false
        ))
        for await event in scanner.scan(root: root) {
            switch event {
            case .permissionDenied(let path):
                permissionDeniedPaths.append(path)
            case .incomplete(let issue):
                issues.append(issue)
            case .failed(let failure):
                failures.append(failure)
            case .finished(let value):
                summary = value
            default:
                break
            }
        }

        XCTAssertEqual(permissionDeniedPaths, [denied.path])
        XCTAssertTrue(failures.isEmpty,
                      "后代目录受限只能产生 partial，不得冒充根级失败：\(failures)")
        XCTAssertEqual(issues, [
            ScanIncompleteIssue(
                path: denied.path,
                reason: .permissionDenied,
                stage: .enumerate,
                posixErrorCode: EACCES
            )
        ])
        XCTAssertEqual(summary?.completionStatus, .partial)
        XCTAssertEqual(summary?.permissionDeniedCount, 1)
        XCTAssertEqual(summary?.incompleteIssues, issues)
    }

    func test_fileManagerScanner_failedEnumerationUsesSameIncompleteContract() async throws {
        let file = try makeTemporaryFile()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: file)) }

        let expected = ScanIncompleteIssue(
            path: file.path,
            reason: .enumerationFailed,
            stage: .enumerate,
            posixErrorCode: ENOTDIR
        )
        var issues: [ScanIncompleteIssue] = []
        var failedEventCount = 0
        var summary: ScanSummary?

        for await event in Scanner().scan(root: file) {
            switch event {
            case .incomplete(let issue):
                issues.append(issue)
            case .failed:
                failedEventCount += 1
            case .finished(let value):
                summary = value
            default:
                break
            }
        }

        XCTAssertEqual(issues, [expected])
        XCTAssertEqual(failedEventCount, 1)
        XCTAssertEqual(summary?.completionStatus, .partial)
        XCTAssertEqual(summary?.incompleteIssues, [expected])
        XCTAssertEqual(summary?.permissionDeniedCount, 0)
    }

    func test_transientPOSIXFailuresRetainStageAndErrnoWithoutBecomingPermissionErrors() {
        for errorCode in [ENOENT, ESTALE] {
            let issue = ScanFailureClassifier.issue(
                path: "/tmp/active-directory/renamed-child",
                stage: .open,
                posixErrorCode: errorCode
            )

            XCTAssertEqual(issue.reason, .enumerationFailed)
            XCTAssertEqual(issue.stage, .open)
            XCTAssertEqual(issue.posixErrorCode, errorCode)
        }
    }

    func test_terminalFailurePolicyOnlyAllowsNonPermissionRootFailures() {
        let root = "/tmp/root"
        let missingRoot = ScanFailureClassifier.issue(
            path: root,
            stage: .open,
            posixErrorCode: ENOENT
        )
        let missingDescendant = ScanFailureClassifier.issue(
            path: "\(root)/active-child",
            stage: .open,
            posixErrorCode: ENOENT
        )
        let deniedRoot = ScanFailureClassifier.issue(
            path: root,
            stage: .open,
            posixErrorCode: EACCES
        )

        XCTAssertTrue(BulkScanner.shouldEmitTerminalFailure(
            rootPath: root,
            directoryPath: root,
            issue: missingRoot
        ))
        XCTAssertFalse(BulkScanner.shouldEmitTerminalFailure(
            rootPath: root,
            directoryPath: "\(root)/active-child",
            issue: missingDescendant
        ))
        XCTAssertFalse(BulkScanner.shouldEmitTerminalFailure(
            rootPath: root,
            directoryPath: root,
            issue: deniedRoot
        ))
    }

    func test_scanSummaryCannotClaimCompleteWhenIncompleteIssuesExist() {
        let root = URL(fileURLWithPath: "/tmp/root", isDirectory: true)
        let issue = ScanIncompleteIssue(
            path: "/tmp/root/denied",
            reason: .permissionDenied
        )

        let summary = ScanSummary(
            root: root,
            totalAllocatedBytes: 0,
            totalLogicalBytes: 0,
            fileCount: 0,
            directoryCount: 0,
            dedupedHardlinkBytes: 0,
            elapsed: 0,
            completionStatus: .complete,
            incompleteIssues: [issue]
        )

        XCTAssertEqual(summary.completionStatus, .partial)
        XCTAssertEqual(summary.incompleteIssues, [issue])
    }
}
