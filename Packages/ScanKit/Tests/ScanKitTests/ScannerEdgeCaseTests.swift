import XCTest
import Darwin
@testable import ScanKit

final class ScannerEdgeCaseTests: XCTestCase {

    /// 制造 chmod 0000 的子目录，断言 BulkScanner 至少 yield 一条 .permissionDenied
    func test_权限被拒目录会发出permissionDenied事件() async throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let denied = tmp.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        // 子目录里写一个文件，确保它如果可读会被列出
        try Data(count: 16).write(to: denied.appendingPathComponent("inside.bin"))

        // 给 root 写一个能正常扫到的文件，确保扫描真的进了根
        try Data(count: 16).write(to: tmp.appendingPathComponent("ok.bin"))

        // 拒访
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let scanner = BulkScanner()
        var sawPermissionDenied = false
        var sawSummary: ScanSummary?
        for await event in scanner.scan(root: tmp) {
            switch event {
            case .permissionDenied(let path):
                if path == denied.path { sawPermissionDenied = true }
            case .finished(let s):
                sawSummary = s
            default:
                break
            }
        }
        XCTAssertTrue(sawPermissionDenied, "应当至少 yield 一条 .permissionDenied 事件")
        XCTAssertNotNil(sawSummary)
    }

    /// summary.permissionDeniedCount 必须等于流里 .permissionDenied 的次数
    func test_summary中permissionDeniedCount与yield次数一致() async throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-permcount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 三个拒访目录
        var deniedPaths: [String] = []
        for i in 0..<3 {
            let d = tmp.appendingPathComponent("denied-\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: d.path)
            deniedPaths.append(d.path)
        }
        defer {
            for p in deniedPaths {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
            }
            try? FileManager.default.removeItem(at: tmp)
        }

        let scanner = BulkScanner()
        var deniedYieldCount = 0
        var summary: ScanSummary?
        for await event in scanner.scan(root: tmp) {
            switch event {
            case .permissionDenied:
                deniedYieldCount += 1
            case .finished(let s):
                summary = s
            default:
                break
            }
        }
        XCTAssertNotNil(summary)
        XCTAssertEqual(summary?.permissionDeniedCount, deniedYieldCount,
                       "summary.permissionDeniedCount 必须与 yield 次数完全一致")
        XCTAssertGreaterThanOrEqual(deniedYieldCount, 3)
    }

    /// 制造 1000 文件 fixture，AsyncStream 不读直接 cancel，断言不死锁（在合理时间内任务能终止）
    func test_AsyncStream在消费阻塞时仍能完成() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scankit-async-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for i in 0..<1000 {
            try Data(count: 4).write(to: tmp.appendingPathComponent("f-\(i).bin"))
        }

        let scanner = BulkScanner()
        let stream = scanner.scan(root: tmp)

        // 启动一个消费 Task，但立即 cancel —— 不读 stream
        let consumer = Task {
            var iter = stream.makeAsyncIterator()
            // 不读一条，直接等取消
            while !Task.isCancelled {
                _ = await iter.next()
            }
        }
        consumer.cancel()

        // 给 5 秒上限：bufferingNewest(8192) 保证 producer 端 yield 不会阻塞，
        // onTermination 会通知 detached task 取消。整个流必须在远短于上限时间结束。
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                _ = await consumer.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "AsyncStream 在消费方 cancel 后必须能在 5 秒内终止，不得死锁")
    }
}
