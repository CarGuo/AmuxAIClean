import Foundation
import XCTest
@testable import LogKit

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
}

final class GSYLogTests: XCTestCase {

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
}
