import Foundation
import Darwin
import XCTest
@testable import LogKit

private final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FailOnceRetentionPreflight: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func call() throws {
        lock.lock()
        let failThisCall = shouldFail
        shouldFail = false
        lock.unlock()
        if failThisCall {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }
}

final class LogFileSinkTests: XCTestCase {

    /// 临时目录辅助。每个测试一个隔离 dir。
    private func makeTempDir(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_append_写入当天文件可被读回() throws {
        let dir = try makeTempDir("append")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        sink.append("hello-1\n")
        sink.append("hello-2\n")
        sink.close()
        let url = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "log" })
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("hello-1"))
        XCTAssertTrue(content.contains("hello-2"))
    }

    func test_currentFileURL_返回当天文件路径() throws {
        let dir = try makeTempDir("currentURL")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        let url = sink.currentFileURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.lastPathComponent.hasPrefix("AmuxAIClean-") ?? false)
        XCTAssertEqual(url?.pathExtension, "log")
        sink.close()
    }

    func test_purge_超过保留期的旧文件被删除() throws {
        let dir = try makeTempDir("purge")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 制造一个 30 天前的旧 log 文件。
        let oldURL = dir.appendingPathComponent("AmuxAIClean-2020-01-01.log")
        FileManager.default.createFile(atPath: oldURL.path, contents: Data("ancient\n".utf8))
        let oldDate = Date().addingTimeInterval(-30 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)
        // 制造一个今天的（同名）作为正常文件，purge 不应误删。
        // 触发 sink 启动时一次性扫描 + 打开当天。
        let sink = try LogFileSink(directory: dir, retentionDays: 7)
        sink.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path), "30 天前的 log 应被清理")
    }

    func test_purge_保留期内的旧文件保留() throws {
        let dir = try makeTempDir("retain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recentURL = dir.appendingPathComponent("AmuxAIClean-2099-01-01.log")
        FileManager.default.createFile(atPath: recentURL.path, contents: Data("recent\n".utf8))
        // mtime = 1 天前，应被保留。
        let recentMtime = Date().addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.modificationDate: recentMtime], ofItemAtPath: recentURL.path)
        let sink = try LogFileSink(directory: dir, retentionDays: 7)
        sink.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path), "1 天前的 log 应保留（< 7 天）")
    }

    func test_purge_不动非log前缀的文件() throws {
        let dir = try makeTempDir("foreign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let alien = dir.appendingPathComponent("user-notes-2020-01-01.log")
        FileManager.default.createFile(atPath: alien.path, contents: Data("alien\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-365 * 86_400)],
                                              ofItemAtPath: alien.path)
        _ = try LogFileSink(directory: dir, retentionDays: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: alien.path),
                      "非 AmuxAIClean- 前缀的文件 sink 不应触碰")
    }

    func test_prepareDirectoryForAccess_目录被移除后重建可见日志文件() async throws {
        let dir = try makeTempDir("prepare-recreate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        sink.close()
        try FileManager.default.removeItem(at: dir)

        guard case .success(let prepared) = await sink.prepareDirectoryForAccess() else {
            return XCTFail("A deleted user log directory should be recreated when it remains writable")
        }
        XCTAssertEqual(prepared, dir)
        XCTAssertEqual(sink.health, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(sink.currentFileURL).path))
        sink.close()
    }

    func test_prepareDirectoryForAccess_失败保留stageDomainCode() async throws {
        let parent = try makeTempDir("prepare-failure")
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("logs", isDirectory: true)
        let sink = try LogFileSink(directory: dir)
        sink.close()
        try FileManager.default.removeItem(at: dir)
        try Data("blocks-directory".utf8).write(to: dir)

        guard case .failure(let failure) = await sink.prepareDirectoryForAccess() else {
            return XCTFail("A regular file at the directory path must be a typed failure")
        }
        XCTAssertEqual(failure.stage, .prepareAccess)
        XCTAssertFalse(failure.errorDomain.isEmpty)
        XCTAssertNotEqual(failure.errorCode, 0)
        XCTAssertEqual(sink.health, .unavailable(failure))
    }

    /// v2026.07.18 P1 regression: FileManager.removeItem recursively deletes directories. A name
    /// that merely resembles one of our logs is never sufficient ownership evidence.
    func test_purge_精确日志名目录也绝不递归删除() throws {
        let dir = try makeTempDir("purge-directory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lookalike = dir.appendingPathComponent(
            "AmuxAIClean-2020-01-01.log",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: false)
        let marker = lookalike.appendingPathComponent("must-survive.txt")
        try Data("owned-by-user".utf8).write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-365 * 86_400)],
            ofItemAtPath: lookalike.path
        )

        let sink = try LogFileSink(directory: dir, retentionDays: 7)
        sink.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func test_clearLogs_仅删除精确命名普通文件且不跟随符号链接() async throws {
        let dir = try makeTempDir("clear-owned-only")
        let outside = try makeTempDir("clear-outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = try LogFileSink(directory: dir)
        let matchingDirectory = dir.appendingPathComponent(
            "AmuxAIClean-2020-01-01.log",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: matchingDirectory,
            withIntermediateDirectories: false
        )
        let marker = matchingDirectory.appendingPathComponent("must-survive.txt")
        try Data("directory".utf8).write(to: marker)

        let outsideFile = outside.appendingPathComponent("outside.txt")
        try Data("outside-secret".utf8).write(to: outsideFile)
        let matchingSymlink = dir.appendingPathComponent("AmuxAIClean-2021-01-01.log")
        try FileManager.default.createSymbolicLink(
            at: matchingSymlink,
            withDestinationURL: outsideFile
        )
        let hardLinkSource = outside.appendingPathComponent("hard-link-source.txt")
        try Data("hard-link-must-survive".utf8).write(to: hardLinkSource)
        let matchingHardLink = dir.appendingPathComponent("AmuxAIClean-2022-02-02.log")
        try FileManager.default.linkItem(at: hardLinkSource, to: matchingHardLink)
        let malformed = dir.appendingPathComponent("AmuxAIClean-2022-1-01.log")
        try Data("lookalike".utf8).write(to: malformed)

        guard case .success = await sink.clearLogs() else {
            return XCTFail("clearLogs should remove only owned regular files")
        }
        sink.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "outside-secret")
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: matchingSymlink.path))
        XCTAssertEqual(
            try String(contentsOf: hardLinkSource, encoding: .utf8),
            "hard-link-must-survive"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: matchingHardLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))
    }

    func test_exportCombined_不读取精确日志名符号链接目标() async throws {
        let dir = try makeTempDir("export-no-follow")
        let outside = try makeTempDir("export-outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = try LogFileSink(directory: dir)
        sink.append("owned-log-line\n")
        let outsideFile = outside.appendingPathComponent("private.txt")
        try Data("must-not-be-exported".utf8).write(to: outsideFile)
        let matchingSymlink = dir.appendingPathComponent("AmuxAIClean-2021-02-03.log")
        try FileManager.default.createSymbolicLink(
            at: matchingSymlink,
            withDestinationURL: outsideFile
        )
        let destination = outside.appendingPathComponent("combined.txt")

        guard case .success = await sink.exportCombined(to: destination) else {
            return XCTFail("export should ignore foreign symlinks and export owned logs")
        }
        sink.close()

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("owned-log-line"))
        XCTAssertFalse(exported.contains("must-not-be-exported"))
        XCTAssertFalse(exported.contains(matchingSymlink.lastPathComponent))
    }

    func test_exportCombined_可见路径unlink后先回放窗口再导出() async throws {
        let dir = try makeTempDir("export-unlink-replay")
        let outputDir = try makeTempDir("export-unlink-replay-output")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 256,
            appendValidationTimeIntervalNanoseconds: .max
        )
        let expected = try XCTUnwrap(sink.currentFileURL)
        sink.append("export-replay-1\n")
        _ = sink.appendValidationDiagnosticsForTesting()
        try FileManager.default.removeItem(at: expected)
        sink.append("export-replay-2\n")
        let destination = outputDir.appendingPathComponent("combined.txt")

        guard case .success = await sink.exportCombined(to: destination) else {
            sink.close()
            return XCTFail("export must first restore the pending visibility window")
        }
        sink.close()

        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(exported.components(separatedBy: "export-replay-1").count - 1, 1)
        XCTAssertEqual(exported.components(separatedBy: "export-replay-2").count - 1, 1)
    }

    func test_prepareDirectoryForAccess_活跃路径被普通文件替换后重绑可见inode() async throws {
        let dir = try makeTempDir("prepare-inode-replacement")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displaced = dir.appendingPathComponent("displaced.log")
        try FileManager.default.moveItem(at: expected, to: displaced)
        try Data("replacement\n".utf8).write(to: expected)

        guard case .success = await sink.prepareDirectoryForAccess() else {
            return XCTFail("A regular replacement must be rebound after fd/path identity mismatch")
        }
        sink.append("after-rebind\n")
        sink.close()

        XCTAssertTrue(try String(contentsOf: expected, encoding: .utf8).contains("after-rebind"))
        XCTAssertFalse(try String(contentsOf: displaced, encoding: .utf8).contains("after-rebind"))
    }

    func test_prepareFailure_隔离旧handle且后续append不能伪造ready() async throws {
        let dir = try makeTempDir("prepare-isolate-handle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        var updates = sink.healthUpdates().makeAsyncIterator()
        let initialHealth = await updates.next()
        XCTAssertEqual(initialHealth, .ready)

        try FileManager.default.removeItem(at: dir)
        try Data("blocks-directory".utf8).write(to: dir)
        guard case .failure(let failure) = await sink.prepareDirectoryForAccess() else {
            return XCTFail("A regular file replacing the directory must fail closed")
        }
        let unavailableHealth = await updates.next()
        XCTAssertEqual(unavailableHealth, .unavailable(failure))

        sink.append("must-not-disappear-into-old-inode\n")
        sink.close()
        guard case .unavailable = sink.health else {
            return XCTFail("A later append must not mark an invalidated/unlinked handle ready")
        }
    }

    func test_logFiles_目录不可枚举返回typedFailure而不是伪装空列表() async throws {
        let dir = try makeTempDir("enumerate-typed-failure")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(directory: dir)
        try FileManager.default.removeItem(at: dir)
        try Data("blocks-directory".utf8).write(to: dir)

        guard case .failure(let failure) = await sink.logFiles() else {
            return XCTFail("An inaccessible log root must not be projected as an empty inventory")
        }
        XCTAssertEqual(failure.stage, .enumerate)
        XCTAssertFalse(failure.errorDomain.isEmpty)
        XCTAssertNotEqual(failure.errorCode, 0)
        sink.close()
    }

    func test_append_普通替换边界按序回放窗口到当前可见inode() async throws {
        let dir = try makeTempDir("append-bounded-rebind")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 1,
            appendValidationTimeIntervalNanoseconds: .max
        )
        sink.append("before-replacement\n")
        guard case .success = await sink.prepareDirectoryForAccess() else {
            return XCTFail("Initial append should be visible before replacement")
        }
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displaced = dir.appendingPathComponent("displaced.log")
        try FileManager.default.moveItem(at: expected, to: displaced)
        try Data("replacement\n".utf8).write(to: expected)

        sink.append("still-original-before-boundary\n")
        sink.append("after-periodic-rebind\n")
        sink.close()

        let replacementContents = try String(contentsOf: expected, encoding: .utf8)
        let originalContents = try String(contentsOf: displaced, encoding: .utf8)
        XCTAssertTrue(replacementContents.contains("after-periodic-rebind"))
        XCTAssertEqual(
            replacementContents.components(separatedBy: "still-original-before-boundary").count - 1,
            1,
            "the current expected pathname receives the pending window exactly once"
        )
        XCTAssertTrue(originalContents.contains("still-original-before-boundary"))
        XCTAssertFalse(originalContents.contains("after-periodic-rebind"))
    }

    func test_append_边界重验遇到符号链接时拒绝换向并关闭writer() async throws {
        let dir = try makeTempDir("append-bounded-symlink")
        let outside = try makeTempDir("append-bounded-symlink-outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 1,
            appendValidationTimeIntervalNanoseconds: .max
        )
        sink.append("before-replacement\n")
        guard case .success = await sink.prepareDirectoryForAccess() else {
            return XCTFail("Initial append should be visible before replacement")
        }
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displaced = dir.appendingPathComponent("displaced.log")
        let foreign = outside.appendingPathComponent("foreign.log")
        try Data("foreign-must-not-change\n".utf8).write(to: foreign)
        try FileManager.default.moveItem(at: expected, to: displaced)
        try FileManager.default.createSymbolicLink(at: expected, withDestinationURL: foreign)

        sink.append("still-original-before-boundary\n")
        sink.append("must-not-follow-symlink\n")
        sink.close()

        XCTAssertEqual(
            try String(contentsOf: foreign, encoding: .utf8),
            "foreign-must-not-change\n"
        )
        let originalContents = try String(contentsOf: displaced, encoding: .utf8)
        XCTAssertTrue(originalContents.contains("still-original-before-boundary"))
        XCTAssertFalse(originalContents.contains("must-not-follow-symlink"))
        guard case .unavailable(let failure) = sink.health else {
            return XCTFail("A symlink discovered at the validation boundary must close the writer")
        }
        XCTAssertEqual(failure.stage, .write)
    }

    func test_append_日志目录被rename并原路径重建后在边界重绑新目录() async throws {
        let root = try makeTempDir("append-bounded-directory-rebind")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 1,
            appendValidationTimeIntervalNanoseconds: .max
        )
        sink.append("before-directory-rename\n")
        guard case .success = await sink.prepareDirectoryForAccess() else {
            return XCTFail("Initial append should be visible before directory replacement")
        }
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displacedDirectory = root.appendingPathComponent("displaced-logs", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: displacedDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        sink.append("still-original-directory-before-boundary\n")
        sink.append("after-directory-rebind\n")
        sink.close()

        let replacementContents = try String(contentsOf: expected, encoding: .utf8)
        let displacedFile = displacedDirectory.appendingPathComponent(expected.lastPathComponent)
        let originalContents = try String(contentsOf: displacedFile, encoding: .utf8)
        XCTAssertTrue(replacementContents.contains("after-directory-rebind"))
        XCTAssertEqual(
            replacementContents.components(
                separatedBy: "still-original-directory-before-boundary"
            ).count - 1,
            1
        )
        XCTAssertTrue(originalContents.contains("still-original-directory-before-boundary"))
        XCTAssertFalse(originalContents.contains("after-directory-rebind"))
    }

    func test_append_可见路径unlink后边界重建并完整回放不可达窗口() throws {
        let dir = try makeTempDir("append-unlink-replay")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 3,
            appendValidationTimeIntervalNanoseconds: .max
        )
        let expected = try XCTUnwrap(sink.currentFileURL)

        sink.append("unlink-window-1\n")
        _ = sink.appendValidationDiagnosticsForTesting()
        try FileManager.default.removeItem(at: expected)
        sink.append("unlink-window-2\n")
        sink.append("unlink-window-3\n")
        sink.append("unlink-boundary-4\n")
        sink.close()

        let visible = try String(contentsOf: expected, encoding: .utf8)
        for token in [
            "unlink-window-1",
            "unlink-window-2",
            "unlink-window-3",
            "unlink-boundary-4"
        ] {
            XCTAssertEqual(
                visible.components(separatedBy: token).count - 1,
                1,
                "every accepted line must be reachable exactly once from the expected pathname"
            )
        }
    }

    func test_append_符号链接失败保留窗口且普通路径恢复后按序回放() throws {
        let dir = try makeTempDir("append-symlink-recovery")
        let outside = try makeTempDir("append-symlink-recovery-outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 1,
            appendValidationTimeIntervalNanoseconds: .max
        )
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displaced = dir.appendingPathComponent("displaced.log")
        let foreign = outside.appendingPathComponent("foreign.log")
        try Data("foreign-must-not-change\n".utf8).write(to: foreign)

        sink.append("recovery-window-1\n")
        _ = sink.appendValidationDiagnosticsForTesting()
        try FileManager.default.moveItem(at: expected, to: displaced)
        try FileManager.default.createSymbolicLink(at: expected, withDestinationURL: foreign)
        sink.append("recovery-window-2\n")
        _ = sink.appendValidationDiagnosticsForTesting()
        guard case .unavailable = sink.health else {
            return XCTFail("a symlink at the visible pathname must fail closed")
        }
        XCTAssertEqual(
            try String(contentsOf: foreign, encoding: .utf8),
            "foreign-must-not-change\n"
        )

        try FileManager.default.removeItem(at: expected)
        sink.append("recovery-window-3\n")
        sink.close()

        let recovered = try String(contentsOf: expected, encoding: .utf8)
        let ordered = ["recovery-window-1", "recovery-window-2", "recovery-window-3"]
        let positions = ordered.compactMap { recovered.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, ordered.count)
        for pair in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        for token in ordered {
            XCTAssertEqual(recovered.components(separatedBy: token).count - 1, 1)
        }
        XCTAssertTrue(
            try String(contentsOf: displaced, encoding: .utf8).contains("recovery-window-1")
        )
    }

    func test_append_恢复时replay超限写显式marker而非静默清空() throws {
        let dir = try makeTempDir("append-replay-overflow")
        let outside = try makeTempDir("append-replay-overflow-outside")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 1,
            appendValidationTimeIntervalNanoseconds: .max,
            visibilityReplayByteCapacity: 40
        )
        let expected = try XCTUnwrap(sink.currentFileURL)
        let displaced = dir.appendingPathComponent("displaced.log")
        let foreign = outside.appendingPathComponent("foreign.log")
        try Data("foreign\n".utf8).write(to: foreign)

        let retained = "retained-" + String(repeating: "a", count: 20) + "\n"
        let overflowed = "overflowed-" + String(repeating: "b", count: 80) + "\n"
        sink.append(retained)
        _ = sink.appendValidationDiagnosticsForTesting()
        try FileManager.default.moveItem(at: expected, to: displaced)
        try FileManager.default.createSymbolicLink(at: expected, withDestinationURL: foreign)
        sink.append(overflowed)
        _ = sink.appendValidationDiagnosticsForTesting()

        try FileManager.default.removeItem(at: expected)
        sink.append("after-overflow-recovery\n")
        sink.close()

        let recovered = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(recovered.contains(retained))
        XCTAssertFalse(recovered.contains(overflowed))
        XCTAssertTrue(recovered.contains("file_log_visibility_replay_overflow"))
        XCTAssertTrue(recovered.contains("dropped_lines=1"))
        XCTAssertTrue(recovered.contains("after-overflow-recovery"))
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "foreign\n")
    }

    func test_append_1500条日志完整保留且路径重验按固定批次增长() throws {
        let dir = try makeTempDir("append-validation-budget")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try LogFileSink(
            directory: dir,
            retentionPreflight: nil,
            appendValidationLineInterval: 256,
            appendValidationTimeIntervalNanoseconds: .max
        )
        let expected = try XCTUnwrap(sink.currentFileURL)

        for index in 0..<1_500 {
            sink.append("structured-line-\(index)\n")
        }
        sink.close()

        let diagnostics = sink.appendValidationDiagnosticsForTesting()
        XCTAssertEqual(diagnostics.successfulWriteCount, 1_500)
        // v2026.07.19 regression contract: boundaries occur before lines 257, 513, 769,
        // 1025 and 1281. Path validation must not grow once per structured log line.
        XCTAssertEqual(diagnostics.periodicValidationCount, 5)
        let data = try Data(contentsOf: expected)
        XCTAssertEqual(data.lazy.filter { $0 == UInt8(ascii: "\n") }.count, 1_500)
    }

    func test_clearLogs_父目录符号链接换向后拒绝跨越冻结边界() async throws {
        let root = try makeTempDir("parent-symlink-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let firstParent = container.appendingPathComponent("parent", isDirectory: true)
        let secondParent = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: false)
        let routedLogs = firstParent.appendingPathComponent("logs", isDirectory: true)
        let sink = try LogFileSink(directory: routedLogs)

        let secondLogs = secondParent.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: secondLogs, withIntermediateDirectories: false)
        let foreign = secondLogs.appendingPathComponent("AmuxAIClean-2020-01-01.log")
        try Data("foreign-must-survive".utf8).write(to: foreign)
        let displacedParent = container.appendingPathComponent("displaced-parent", isDirectory: true)
        try FileManager.default.moveItem(at: firstParent, to: displacedParent)
        try FileManager.default.createSymbolicLink(at: firstParent, withDestinationURL: secondParent)

        guard case .failure(let failure) = await sink.clearLogs() else {
            return XCTFail("A parent symlink swap must fail closed instead of clearing the new target")
        }
        XCTAssertEqual(failure.stage, .clear)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "foreign-must-survive")
        guard case .unavailable = sink.health else {
            return XCTFail("clear failure closes the writer and must make health unavailable")
        }
    }

    func test_init_父目录符号链接越界时拒绝且不在目标创建任何子目录() throws {
        let root = try makeTempDir("init-no-follow-before-create")
        defer { try? FileManager.default.removeItem(at: root) }
        let route = root.appendingPathComponent("route", isDirectory: true)
        let outside = FileManager.default.homeDirectoryForCurrentUser
        try FileManager.default.createSymbolicLink(at: route, withDestinationURL: outside)
        let childName = "LogFileSink-must-not-create-\(UUID().uuidString)"
        let requested = route.appendingPathComponent(childName, isDirectory: true)
        let forbiddenTarget = outside.appendingPathComponent(childName, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbiddenTarget.path))

        XCTAssertThrowsError(try LogFileSink(directory: requested))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: forbiddenTarget.path),
            "Boundary validation must happen before any create follows the parent symlink"
        )
    }

    func test_failureDomain_公开诊断只保留白名单domain() {
        XCTAssertEqual(
            LogFileSinkFailure(stage: .open, errorDomain: NSPOSIXErrorDomain, errorCode: 13)
                .errorDomain,
            NSPOSIXErrorDomain
        )
        XCTAssertEqual(
            LogFileSinkFailure(stage: .open, errorDomain: "/Users/private/path", errorCode: 13)
                .errorDomain,
            "UnknownErrorDomain"
        )
    }

    func test_retentionFailure_保持writerReady并在同阶段成功重试后清除() async throws {
        let dir = try makeTempDir("retention-observable")
        defer { try? FileManager.default.removeItem(at: dir) }
        let preflight = FailOnceRetentionPreflight()
        let sink = try LogFileSink(
            directory: dir,
            retentionDays: 7,
            retentionPreflight: { try preflight.call() }
        )
        defer { sink.close() }

        XCTAssertEqual(sink.health, .ready, "retention maintenance does not invalidate append")
        XCTAssertEqual(sink.issues.failures.count, 1)
        XCTAssertEqual(sink.issues.failures.first?.stage, .retention)
        var issueUpdates = sink.issueUpdates().makeAsyncIterator()
        let initialIssues = await issueUpdates.next()
        XCTAssertEqual(initialIssues?.failures.first?.stage, .retention)

        guard case .success = await sink.prepareDirectoryForAccess() else {
            return XCTFail("a valid writer directory should remain accessible")
        }
        let clearedIssues = await issueUpdates.next()
        XCTAssertEqual(clearedIssues, .empty)
        XCTAssertEqual(sink.health, .ready)
        XCTAssertEqual(sink.issues, .empty)
    }

    func test_copyDescriptorContents_固定块流式复制保持字节顺序() throws {
        let dir = try makeTempDir("bounded-copy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("source.bin")
        let destinationURL = dir.appendingPathComponent("destination.bin")
        let payload = Data((0..<131_123).map { UInt8($0 % 251) })
        try payload.write(to: sourceURL)

        let source = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(source, 0)
        defer { if source >= 0 { Darwin.close(source) } }
        let destination = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertGreaterThanOrEqual(destination, 0)
        defer { if destination >= 0 { Darwin.close(destination) } }
        guard source >= 0, destination >= 0 else { return }

        let summary = try LogFileSink.copyDescriptorContents(
            from: source,
            to: destination,
            chunkBytes: 4_096
        )
        XCTAssertEqual(summary.totalBytes, Int64(payload.count))
        XCTAssertLessThanOrEqual(summary.maximumChunkBytes, 4_096)
        XCTAssertEqual(summary.lastByte, payload.last)
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
    }

    func test_exportCombined_流式原子替换既有目标且不遗留临时文件() async throws {
        let dir = try makeTempDir("streaming-export")
        let outputDir = try makeTempDir("streaming-export-output")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: outputDir)
        }
        let sink = try LogFileSink(directory: dir)
        let largeLine = "bounded-export-marker-" + String(repeating: "x", count: 200_000) + "\n"
        sink.append(largeLine)
        let destination = outputDir.appendingPathComponent("combined.txt")
        try Data("old-destination".utf8).write(to: destination)

        guard case .success(let count) = await sink.exportCombined(to: destination) else {
            sink.close()
            return XCTFail("streaming export should atomically replace the selected target")
        }
        sink.close()

        XCTAssertEqual(count, 1)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("bounded-export-marker-"))
        XCTAssertFalse(exported.contains("old-destination"))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: outputDir.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".AmuxAIClean-Logs.") })
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_healthStream_并发注册与failure转移始终先initial后新状态() async throws {
        let state = LogFileSinkHealthState(.ready)
        let registered = DispatchSemaphore(value: 0)
        let releaseRegistration = DispatchSemaphore(value: 0)
        let streamReady = DispatchSemaphore(value: 0)
        let updateStarted = DispatchSemaphore(value: 0)
        let updateFinished = DispatchSemaphore(value: 0)
        let streamBox = LockedTestBox<AsyncStream<LogFileSinkHealth>>()

        DispatchQueue.global().async {
            let stream = state.stream {
                registered.signal()
                releaseRegistration.wait()
            }
            streamBox.set(stream)
            streamReady.signal()
        }
        XCTAssertEqual(registered.wait(timeout: .now() + 2), .success)

        let failure = LogFileSinkFailure(
            stage: .write,
            errorDomain: NSPOSIXErrorDomain,
            errorCode: Int(EIO)
        )
        DispatchQueue.global().async {
            updateStarted.signal()
            _ = state.update(.unavailable(failure))
            updateFinished.signal()
        }
        XCTAssertEqual(updateStarted.wait(timeout: .now() + 2), .success)
        // The update is now contending with registration's health lock. Releasing registration
        // must enqueue `.ready` before the waiting transition can enqueue `.unavailable`.
        releaseRegistration.signal()
        XCTAssertEqual(streamReady.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(updateFinished.wait(timeout: .now() + 2), .success)

        var iterator = try XCTUnwrap(streamBox.get()).makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first, .ready)
        XCTAssertEqual(second, .unavailable(failure))
    }
}

final class GSYLogTests: XCTestCase {

    private func combinedLogContents(in directories: [URL]) throws -> String {
        var combined = ""
        for directory in directories {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "log" }
            for file in files {
                combined += try String(contentsOf: file, encoding: .utf8)
            }
        }
        return combined
    }

    func test_GSYLog_levelOrdering() {
        XCTAssertLessThan(GSYLog.Level.debug, GSYLog.Level.info)
        XCTAssertLessThan(GSYLog.Level.info, GSYLog.Level.notice)
        XCTAssertLessThan(GSYLog.Level.notice, GSYLog.Level.warning)
        XCTAssertLessThan(GSYLog.Level.warning, GSYLog.Level.error)
    }

    func test_GSYLog_configure_文件sink可写() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-configure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: dir)
        }
        let sink = try LogFileSink(directory: dir)
        GSYLog.configure(minimumLevel: .debug, fileSink: sink)
        GSYLog.info(.app, "test-line-from-info")
        GSYLog.error(.scan, "test-line-from-error")
        // 强制 flush。
        sink.close()
        let url = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "log" })
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("test-line-from-info"))
        XCTAssertTrue(content.contains("test-line-from-error"))
        XCTAssertTrue(content.contains("[App]"))
        XCTAssertTrue(content.contains("[Scan]"))
        XCTAssertTrue(content.contains("[INFO]"))
        XCTAssertTrue(content.contains("[ERROR]"))
    }

    func test_GSYLog_minimumLevel_拦截低于阈值的日志() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-threshold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: dir)
        }
        let sink = try LogFileSink(directory: dir)
        GSYLog.configure(minimumLevel: .warning, fileSink: sink)
        GSYLog.debug(.app, "should-not-appear")
        GSYLog.info(.app, "should-not-appear")
        GSYLog.warning(.app, "must-appear")
        sink.close()
        let url = try XCTUnwrap(try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.pathExtension == "log" })
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("should-not-appear"))
        XCTAssertTrue(content.contains("must-appear"))
    }

    func test_GSYLog_backgroundBootstrap_有界保序并持续转发writerHealth() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: dir)
        }

        let revision = GSYLog.beginFileSinkBootstrap(
            minimumLevel: .debug,
            startupBufferCapacity: 3
        )
        XCTAssertEqual(GSYLog.fileSinkHealth, .initializing)
        var healthUpdates = GSYLog.fileSinkHealthUpdates().makeAsyncIterator()
        let initialHealth = await healthUpdates.next()
        XCTAssertEqual(initialHealth, .initializing)

        GSYLog.info(.app, "startup-early-1")
        GSYLog.info(.app, "startup-early-2")
        GSYLog.info(.app, "startup-early-3")
        GSYLog.info(.app, "startup-early-4")
        let sink = try LogFileSink(directory: dir)
        XCTAssertTrue(GSYLog.completeFileSinkBootstrap(sink, revision: revision))
        let readyHealth = await healthUpdates.next()
        XCTAssertEqual(readyHealth, .ready)
        GSYLog.info(.app, "startup-late")
        sink.close()

        let logURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "log" }
        )
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(content.contains("startup-early-1"))
        let orderedTokens = [
            "startup_file_log_buffer_dropped count=1",
            "startup-early-2",
            "startup-early-3",
            "startup-early-4",
            "startup-late"
        ]
        let positions = orderedTokens.compactMap { content.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, orderedTokens.count)
        for pair in zip(positions, positions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }

        try FileManager.default.removeItem(at: dir)
        try Data("blocks-log-directory".utf8).write(to: dir)
        guard case .failure(let failure) = await sink.prepareDirectoryForAccess() else {
            return XCTFail("the replaced directory must make writer health unavailable")
        }
        let relayedFailure = await healthUpdates.next()
        XCTAssertEqual(relayedFailure, .unavailable(failure))
        XCTAssertEqual(GSYLog.fileSinkHealth, .unavailable(failure))
    }

    func test_GSYLog_staleBootstrapRevision_不能覆盖新配置() throws {
        let firstDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-stale-first-\(UUID().uuidString)", isDirectory: true)
        let secondDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-stale-second-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        defer {
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }

        let staleRevision = GSYLog.beginFileSinkBootstrap(minimumLevel: .debug)
        let currentRevision = GSYLog.beginFileSinkBootstrap(minimumLevel: .debug)
        let staleSink = try LogFileSink(directory: firstDir)
        let currentSink = try LogFileSink(directory: secondDir)

        XCTAssertFalse(GSYLog.completeFileSinkBootstrap(staleSink, revision: staleRevision))
        XCTAssertTrue(GSYLog.completeFileSinkBootstrap(currentSink, revision: currentRevision))
        XCTAssertEqual(GSYLog.currentLogDirectory, secondDir)
        staleSink.close()
        currentSink.close()
    }

    func test_GSYLog_disable_异步拥有旧sink直到已接受append完整drain() async throws {
        GSYLog.disableFileSink()
        await GSYLog.waitForFileSinkRetirementsForTesting()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-disable-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let barrierEntered = DispatchSemaphore(value: 0)
        let releaseBarrier = DispatchSemaphore(value: 0)
        defer {
            releaseBarrier.signal()
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: dir)
        }

        var localSink: LogFileSink? = try LogFileSink(directory: dir)
        localSink?.enqueueBarrierForTesting(
            entered: { barrierEntered.signal() },
            waitForRelease: { releaseBarrier.wait() }
        )
        GSYLog.configure(minimumLevel: .debug, fileSink: localSink)
        XCTAssertEqual(barrierEntered.wait(timeout: .now() + 2), .success)

        let lineCount = 300
        for index in 0..<lineCount {
            GSYLog.info(.app, "disable-drain[\(index)]")
        }
        // Drop the test's reference before disable. Only the facade retirement lifecycle may keep
        // the blocked sink alive and drain the already accepted append blocks.
        localSink = nil
        GSYLog.disableFileSink()
        releaseBarrier.signal()
        await GSYLog.waitForFileSinkRetirementsForTesting()

        let contents = try combinedLogContents(in: [dir])
        for index in 0..<lineCount {
            XCTAssertEqual(
                contents.components(separatedBy: "disable-drain[\(index)]").count - 1,
                1
            )
        }
    }

    func test_GSYLog_emit与reconfigure竞争_每条只进入交接两侧之一且无retire后丢失() async throws {
        GSYLog.disableFileSink()
        await GSYLog.waitForFileSinkRetirementsForTesting()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LogKitTests-reconfigure-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            GSYLog.disableFileSink()
            try? FileManager.default.removeItem(at: root)
        }
        let directories = (0..<5).map {
            root.appendingPathComponent("sink-\($0)", isDirectory: true)
        }
        for directory in directories {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        GSYLog.configure(
            minimumLevel: .debug,
            fileSink: try LogFileSink(directory: directories[0])
        )

        let lineCount = 400
        let transitionCount = directories.count - 1
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let constructionError = LockedTestBox<Error>()
        for index in 0..<lineCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                GSYLog.info(.scan, "handoff-race[\(index)]")
                group.leave()
            }
        }
        for directory in directories.dropFirst() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                start.wait()
                do {
                    GSYLog.configure(
                        minimumLevel: .debug,
                        fileSink: try LogFileSink(directory: directory)
                    )
                } catch {
                    constructionError.set(error)
                }
                group.leave()
            }
        }
        for _ in 0..<(lineCount + transitionCount) { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertNil(constructionError.get())

        GSYLog.disableFileSink()
        await GSYLog.waitForFileSinkRetirementsForTesting()
        let contents = try combinedLogContents(in: directories)
        for index in 0..<lineCount {
            XCTAssertEqual(
                contents.components(separatedBy: "handoff-race[\(index)]").count - 1,
                1,
                "the shared emit/config lock must route one accepted line to exactly one sink"
            )
        }
    }
}
