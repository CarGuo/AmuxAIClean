import Darwin
import Foundation
import XCTest
@testable import ScanKit

/// 版本化根发现不能把 I/O 缺口伪装成“完整扫描但没有旧版本”。
///
/// 使用故障注入文件系统而不是 chmod/race，确保权限、枚举和 metadata 分支在本机与 CI
/// 都可重复。所有真实文件只创建在 NSTemporaryDirectory 下，测试不执行回收操作。
final class VersionedRootDiscoveryEvidenceTests: XCTestCase {

    func test_detectWithEvidence_可选根不存在_仍是完整空结果() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("VersionedRootMissing-\(UUID().uuidString)", isDirectory: true)

        let result = VersionedRetainScanner.detectWithEvidence(collectionRoot: missing)

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.incompleteIssues.isEmpty)
        XCTAssertTrue(result.isComplete, "未安装的可选工具根不是扫描失败")
    }

    func test_detectWithEvidence_根目录枚举被拒绝_返回权限证据() throws {
        let root = try makeDirectory(named: "EnumerationDenied")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }

        let fileSystem = FaultInjectingVersionedFileSystem(
            enumerationPermissionFailurePaths: [root.path]
        )
        let result = VersionedRetainScanner.detectWithEvidence(
            collectionRoot: root,
            options: .default,
            fileSystem: fileSystem
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(
            result.incompleteIssues,
            [ScanIncompleteIssue(path: root.path, reason: .permissionDenied)]
        )
        XCTAssertFalse(result.isComplete)
    }

    func test_detectWithEvidence_候选子目录metadata失败_不输出不可信旧版本() throws {
        let root = try makeDirectory(named: "ChildMetadata")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try makeVersions(root: root, names: ["1.0", "2.0", "3.0", "4.0"])
        let failedChild = root.appendingPathComponent("4.0", isDirectory: true)

        let fileSystem = FaultInjectingVersionedFileSystem(
            metadataFailurePaths: [failedChild.path]
        )
        let result = VersionedRetainScanner.detectWithEvidence(
            collectionRoot: root,
            options: .init(keepLatest: 2, ordering: .semverPreferred),
            fileSystem: fileSystem
        )

        XCTAssertTrue(
            result.hits.isEmpty,
            "缺失的子目录可能正是最新版本，不能基于剩余候选推导可删除旧版本"
        )
        XCTAssertEqual(
            result.incompleteIssues,
            [ScanIncompleteIssue(path: failedChild.path, reason: .metadataUnavailable)]
        )
    }

    func test_detectWithEvidence_mtime排序缺少日期_返回metadata证据() throws {
        let root = try makeDirectory(named: "MissingMtime")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try makeVersions(root: root, names: ["A", "B", "C"])
        let missingDate = root.appendingPathComponent("B", isDirectory: true)

        let fileSystem = FaultInjectingVersionedFileSystem(
            missingModificationDatePaths: [missingDate.path]
        )
        let result = VersionedRetainScanner.detectWithEvidence(
            collectionRoot: root,
            options: .init(keepLatest: 1, ordering: .modificationDateDescending),
            fileSystem: fileSystem
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(
            result.incompleteIssues,
            [ScanIncompleteIssue(path: missingDate.path, reason: .metadataUnavailable)]
        )
    }

    func test_detectWithEvidence_允许软链时目标metadata失败_返回证据() throws {
        let root = try makeDirectory(named: "BrokenSymlink")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        try makeVersions(root: root, names: ["1.0", "2.0"])
        let brokenLink = root.appendingPathComponent("3.0")
        try FileManager.default.createSymbolicLink(
            atPath: brokenLink.path,
            withDestinationPath: "missing-target"
        )

        let result = VersionedRetainScanner.detectWithEvidence(
            collectionRoot: root,
            options: .init(
                keepLatest: 1,
                ordering: .semverPreferred,
                skipSymlinks: false
            )
        )

        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(
            result.incompleteIssues,
            [ScanIncompleteIssue(path: brokenLink.path, reason: .metadataUnavailable)]
        )
    }

    func test_scanAllWithEvidence_聚合所有entry与group_仅封锁失败分组() throws {
        let home = try makeDirectory(named: "KnownRootsHome")
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: home)) }

        let iosRoot = home.appendingPathComponent(
            "Library/Developer/Xcode/iOS DeviceSupport",
            isDirectory: true
        )
        try makeVersions(root: iosRoot, names: ["15.0", "16.0", "17.0", "18.0"])

        let watchRoot = home.appendingPathComponent(
            "Library/Developer/Xcode/watchOS DeviceSupport",
            isDirectory: true
        )
        try makeVersions(root: watchRoot, names: ["9.0", "10.0", "11.0"])

        let cachesRoot = home.appendingPathComponent(
            "Library/Caches/JetBrains",
            isDirectory: true
        )
        try makeVersions(root: cachesRoot, names: [
            "IntelliJIdea2024.1",
            "IntelliJIdea2024.2",
            "IntelliJIdea2024.3",
            "PyCharm2024.1",
            "PyCharm2024.2",
        ])
        let failedPyCharm = cachesRoot.appendingPathComponent(
            "PyCharm2024.2",
            isDirectory: true
        )

        let fileSystem = FaultInjectingVersionedFileSystem(
            enumerationPermissionFailurePaths: [watchRoot.path],
            metadataFailurePaths: [failedPyCharm.path]
        )
        let result = KnownVersionedRoots.scanAllWithEvidence(
            home: home,
            fileSystem: fileSystem
        )

        XCTAssertEqual(
            Set(result.hits.filter {
                $0.ruleID == "apple.ios-device-support.versioned"
            }.map(\.versionName)),
            ["15.0", "16.0"]
        )
        XCTAssertEqual(
            Set(result.hits.filter {
                $0.ruleID == "jetbrains.caches.versioned-per-product"
                    && $0.groupKey == "IntelliJIdea"
            }.map(\.versionName)),
            ["IntelliJIdea2024.1", "IntelliJIdea2024.2"]
        )
        XCTAssertTrue(
            result.hits.allSatisfy { $0.groupKey != "PyCharm" },
            "PyCharm 候选集不完整，只封锁该产品组；不应牵连完整的 IntelliJIdea 组"
        )
        XCTAssertEqual(
            Set(result.incompleteIssues),
            [
                ScanIncompleteIssue(path: watchRoot.path, reason: .permissionDenied),
                ScanIncompleteIssue(path: failedPyCharm.path, reason: .metadataUnavailable),
            ]
        )
        XCTAssertFalse(result.isComplete)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVersions(root: URL, names: [String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }
}

private struct FaultInjectingVersionedFileSystem: VersionedRootFileSystem {
    let enumerationPermissionFailurePaths: Set<String>
    let enumerationFailurePaths: Set<String>
    let metadataFailurePaths: Set<String>
    let missingModificationDatePaths: Set<String>

    init(
        enumerationPermissionFailurePaths: Set<String> = [],
        enumerationFailurePaths: Set<String> = [],
        metadataFailurePaths: Set<String> = [],
        missingModificationDatePaths: Set<String> = []
    ) {
        self.enumerationPermissionFailurePaths = enumerationPermissionFailurePaths
        self.enumerationFailurePaths = enumerationFailurePaths
        self.metadataFailurePaths = metadataFailurePaths
        self.missingModificationDatePaths = missingModificationDatePaths
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if metadataFailurePaths.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        var attributes = try FileManager.default.attributesOfItem(atPath: path)
        if missingModificationDatePaths.contains(path) {
            attributes.removeValue(forKey: .modificationDate)
        }
        return attributes
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        if enumerationPermissionFailurePaths.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        if enumerationFailurePaths.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try FileManager.default.contentsOfDirectory(atPath: path)
    }

    func destinationOfSymbolicLink(atPath path: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}
