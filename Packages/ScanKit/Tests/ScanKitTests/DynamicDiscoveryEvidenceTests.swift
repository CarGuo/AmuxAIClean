import XCTest
@testable import ScanKit

final class DynamicDiscoveryEvidenceTests: XCTestCase {
    private let fileManager = FileManager.default

    private func makeHome() throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("DynamicDiscoveryEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: home.path) {
                try fileManager.removeItem(at: home)
            }
        }
        return home
    }

    func test_derivedData_可选根不存在_是完整空结果() throws {
        let home = try makeHome()

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [])
        XCTAssertTrue(result.isComplete)
    }

    func test_derivedData_根枚举拒绝_返回permissionEvidence而非完整空结果() throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            enumerationFailures: [root.path: posixError(EACCES)]
        )

        let result = try DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: root.path, reason: .permissionDenied)
        ])
        XCTAssertFalse(result.isComplete)
    }

    func test_derivedData_单个工程metadata失败_保留其它hit并暴露缺口() throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData",
            isDirectory: true
        )
        let healthy = root.appendingPathComponent("Healthy-abc", isDirectory: true)
        let failed = root.appendingPathComponent("Failed-def", isDirectory: true)
        try fileManager.createDirectory(at: healthy, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            metadataFailures: [failed.path: posixError(EIO)]
        )

        let result = try DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits.map(\.url), [healthy])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: failed.path, reason: .metadataUnavailable)
        ])
    }

    /// v2026.07.18 regression：缺失 info.plist 由稳定 hash 形状识别，不产生虚假 incomplete。
    func test_derivedData_infoPlist缺失_哈希目录仍是完整工程结果() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/Healthy-abc",
            isDirectory: true
        )
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits.map(\.url), [project])
        XCTAssertEqual(result.incompleteIssues, [])
    }

    func test_derivedData_infoPlist缺失_非哈希目录是普通共享目录而非缺口() throws {
        let home = try makeHome()
        let sharedDirectory = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/SharedCache",
            isDirectory: true
        )
        try fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [])
    }

    func test_derivedData_infoPlist权限拒绝_非哈希目录返回typedIncomplete() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/CustomLocation",
            isDirectory: true
        )
        let marker = project.appendingPathComponent("info.plist")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            dataFailures: [marker.path: posixError(EACCES)]
        )

        let result = try DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(
                path: marker.path,
                reason: .permissionDenied,
                stage: .metadata,
                posixErrorCode: EACCES
            )
        ])
    }

    func test_derivedData_infoPlist损坏_非哈希目录返回metadataIncomplete() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/CustomLocation",
            isDirectory: true
        )
        let marker = project.appendingPathComponent("info.plist")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: marker)

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(
                path: marker.path,
                reason: .metadataUnavailable,
                stage: .metadata
            )
        ])
    }

    func test_derivedData_infoPlist超限_非哈希目录返回metadataIncomplete() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/CustomOversize",
            isDirectory: true
        )
        let marker = project.appendingPathComponent("info.plist")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(atPath: marker.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: marker)
        try handle.truncate(atOffset: UInt64(BoundedLocalFileReader.defaultMaximumBytes + 1))
        try handle.close()

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: marker.path, reason: .metadataUnavailable, stage: .metadata)
        ])
    }

    func test_derivedData_infoPlist符号链接_非哈希目录返回metadataIncomplete() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/CustomLinked",
            isDirectory: true
        )
        let marker = project.appendingPathComponent("info.plist")
        let external = home.appendingPathComponent("external.plist")
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": "/tmp/Outside.xcworkspace"],
            format: .xml,
            options: 0
        )
        try plist.write(to: external)
        try fileManager.createSymbolicLink(at: marker, withDestinationURL: external)

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: marker.path, reason: .metadataUnavailable, stage: .metadata)
        ])
    }

    func test_derivedData_infoPlist非普通文件_非哈希目录返回metadataIncomplete() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/CustomDirectoryMarker",
            isDirectory: true
        )
        let marker = project.appendingPathComponent("info.plist", isDirectory: true)
        try fileManager.createDirectory(at: marker, withIntermediateDirectories: true)

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: marker.path, reason: .metadataUnavailable, stage: .metadata)
        ])
    }

    func test_derivedData_infoPlist损坏_哈希身份独立成立不破坏完整容量证据() throws {
        let home = try makeHome()
        let project = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/Healthy-abc",
            isDirectory: true
        )
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: project.appendingPathComponent("info.plist"))

        let result = DerivedDataPerProjectScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits.map(\.url), [project])
        XCTAssertEqual(result.incompleteIssues, [])
    }

    func test_derivedData_异步取消_抛CancellationError且不伪造IncompleteIssue() async throws {
        let home = try makeHome()
        let scanner = DerivedDataPerProjectScanner()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await scanner.discoverWithEvidence(home: home, includeSizes: false)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消必须独立抛出 CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("取消不应被转换为其它错误: \(error)")
        }
    }

    func test_nodeModules_根metadata拒绝_返回permissionEvidence() throws {
        let home = try makeHome()
        let developerRoot = home.appendingPathComponent("Developer", isDirectory: true)
        try fileManager.createDirectory(at: developerRoot, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            metadataFailures: [developerRoot.path: posixError(EPERM)]
        )

        let result = try NodeModulesScanner.detectWithEvidence(
            home: home,
            maxDepth: 4,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: developerRoot.path, reason: .permissionDenied)
        ])
    }

    func test_nodeModules_五个可选根都不存在_是完整空结果() throws {
        let home = try makeHome()

        let result = NodeModulesScanner.detectWithEvidence(
            home: home,
            includeSizes: false
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [])
        XCTAssertTrue(result.isComplete)
    }

    func test_nodeModules_子目录读取失败_保留其它根hit并暴露enumerationEvidence() throws {
        let home = try makeHome()
        let broken = home.appendingPathComponent("Developer/broken", isDirectory: true)
        let healthy = home.appendingPathComponent(
            "Projects/healthy/node_modules",
            isDirectory: true
        )
        try fileManager.createDirectory(at: broken, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: healthy, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            enumerationFailures: [broken.path: posixError(EIO)]
        )

        let result = try NodeModulesScanner.detectWithEvidence(
            home: home,
            maxDepth: 4,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits.map(\.url), [healthy])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: broken.path, reason: .enumerationFailed)
        ])
    }

    func test_nodeModules_候选metadata失败_不能伪装成完整无命中() throws {
        let home = try makeHome()
        let nodeModules = home.appendingPathComponent(
            "Developer/app/node_modules",
            isDirectory: true
        )
        try fileManager.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            metadataFailures: [nodeModules.path: posixError(EIO)]
        )

        let result = try NodeModulesScanner.detectWithEvidence(
            home: home,
            maxDepth: 4,
            includeSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits, [])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: nodeModules.path, reason: .metadataUnavailable)
        ])
    }

    func test_nodeModules_异步取消_抛CancellationError() async throws {
        let home = try makeHome()
        let scanner = NodeModulesScanner()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await scanner.discoverWithEvidence(home: home, includeSizes: false)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消必须独立抛出 CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("取消不应被转换为其它错误: \(error)")
        }
    }

    func test_workflowRegistry_透传同一扫描会话的hits与evidence() async throws {
        let home = try makeHome()
        let root = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData",
            isDirectory: true
        )
        let healthy = root.appendingPathComponent("Healthy-abc", isDirectory: true)
        let failed = root.appendingPathComponent("Failed-def", isDirectory: true)
        try fileManager.createDirectory(at: healthy, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: failed, withIntermediateDirectories: true)
        let fileSystem = FaultInjectingDynamicFileSystem(
            metadataFailures: [failed.path: posixError(EIO)]
        )

        let result = try await WorkflowRegistry.resolveWithEvidence(
            scannerID: "scanner.derived-data-per-project",
            home: home,
            executor: nil,
            includeFilesystemSizes: false,
            fileSystem: fileSystem,
            cancellationCheck: {}
        )

        XCTAssertEqual(result.hits.map(\.url), [healthy])
        XCTAssertEqual(result.incompleteIssues, [
            ScanIncompleteIssue(path: failed.path, reason: .metadataUnavailable)
        ])
    }

    func test_workflowRegistry_异步取消_抛CancellationError() async throws {
        let home = try makeHome()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await WorkflowRegistry.resolveWithEvidence(
                scannerID: "scanner.derived-data-per-project",
                home: home,
                includeFilesystemSizes: false
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("WorkflowRegistry 取消必须独立抛出 CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("取消不应被转换为其它错误: \(error)")
        }
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private struct FaultInjectingDynamicFileSystem: DynamicDiscoveryFileSystem {
    let metadataFailures: [String: NSError]
    let enumerationFailures: [String: NSError]
    let dataFailures: [String: NSError]

    init(
        metadataFailures: [String: NSError] = [:],
        enumerationFailures: [String: NSError] = [:],
        dataFailures: [String: NSError] = [:]
    ) {
        self.metadataFailures = metadataFailures
        self.enumerationFailures = enumerationFailures
        self.dataFailures = dataFailures
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if let error = metadataFailures[path] { throw error }
        return try FileManager.default.attributesOfItem(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) throws -> [String] {
        if let error = enumerationFailures[path] { throw error }
        return try FileManager.default.contentsOfDirectory(atPath: path)
    }

    func canonicalPath(for url: URL) -> String {
        FileManager.default.canonicalPath(for: url)
    }

    func dataContents(
        of url: URL,
        maximumBytes: Int,
        shouldCancel: @Sendable () -> Bool
    ) throws -> Data {
        if shouldCancel() { throw BoundedLocalFileReadError.cancelled }
        if let error = dataFailures[url.path] { throw error }
        return try BoundedLocalFileReader.read(
            at: url,
            maximumBytes: maximumBytes,
            shouldCancel: shouldCancel
        )
    }
}
