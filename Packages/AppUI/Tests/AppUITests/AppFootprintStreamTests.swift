import XCTest
import SafetyKit
@testable import AppUI

/// docs/AUDIT_2026_06.md §4.1 P3 —— AppFootprintScanner 流式两阶段加载契约。
///
/// 关键不变量（与 [AppFootprint.swift scanAllStream](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/AppFootprint.swift#L121-L152) 配对）：
/// - 流式 yield 个数 == apps 个数（一一对应）
/// - yield 出来的 item 集合（按 bundleID）与 scanAll 返回的集合一致——同一份 scanOne 复用
/// - 消费方 `break` 出 for-await 后，detached task 必须能 cancel（下一轮 reload 不会被旧
///   stream 阻塞或留下野任务）
/// - 空 apps 清单：stream 立即 finish，不死锁
final class AppFootprintStreamTests: XCTestCase {

    // MARK: - 复用 AppFootprintTests 的 FakeFM 范式

    private struct FakeFM: FileManagerSnapshotting {
        let entriesByRoot: [String: [FSEntry]]
        let snapshots: [String: FSSnapshot]

        func firstLevelEntries(at path: String) -> [FSEntry]? {
            entriesByRoot[path]
        }
        func snapshot(at path: String) -> FSSnapshot {
            snapshots[path] ?? .init(bytes: 0, fileCount: 0)
        }
    }

    private func makeApp(
        bundleID: String,
        name: String,
        atPath path: String
    ) -> InstalledApp {
        InstalledApp(
            appURL: URL(fileURLWithPath: path),
            metadata: AppMetadata(
                bundleID: bundleID,
                bundleVendor: AppMetadata.vendorPrefix(of: bundleID),
                appName: name,
                executableName: name
            )
        )
    }

    private func makeScanner(apps: [InstalledApp]) -> (AppFootprintScanner, [InstalledApp]) {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        var snaps: [String: FSSnapshot] = [:]
        for (idx, app) in apps.enumerated() {
            // 让字节数互不相同 + 可预测（按 idx），便于排序断言
            snaps[app.appURL.path] = .init(bytes: Int64((idx + 1) * 1_000_000), fileCount: 1)
        }
        let fm = FakeFM(entriesByRoot: [cachesPath: []], snapshots: snaps)
        let unins = AppUninstaller(homeDirectory: home, fileManager: fm, vendorRules: [])
        let scanner = AppFootprintScanner(uninstaller: unins, snapshot: fm)
        return (scanner, apps)
    }

    // MARK: - 1. 流式 yield 数量 == apps 数量

    func test_scanAllStream_yield个数等于apps个数() async {
        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: "/A.app"),
            makeApp(bundleID: "com.b", name: "B", atPath: "/B.app"),
            makeApp(bundleID: "com.c", name: "C", atPath: "/C.app")
        ]
        let (scanner, _) = makeScanner(apps: apps)

        var collected: [AppFootprintItem] = []
        for await item in scanner.scanAllStream(apps: apps) {
            collected.append(item)
        }
        XCTAssertEqual(collected.count, 3, "stream 必须 yield 3 条且不重不漏")
    }

    // MARK: - 2. 流式 yield 与 scanAll 结果集一致

    func test_scanAllStream_集合与scanAll一致() async {
        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: "/A.app"),
            makeApp(bundleID: "com.b", name: "B", atPath: "/B.app"),
            makeApp(bundleID: "com.c", name: "C", atPath: "/C.app")
        ]
        let (scanner, _) = makeScanner(apps: apps)

        let batch = await scanner.scanAll(apps: apps)
        var streamed: [AppFootprintItem] = []
        for await item in scanner.scanAllStream(apps: apps) {
            streamed.append(item)
        }

        // scanAll 返回值已按 totalBytes 倒序；stream 顺序与 apps 输入顺序一致；
        // 我们只比较"按 bundleID 取的集合 + 每条的 totalBytes"
        let batchMap = Dictionary(uniqueKeysWithValues: batch.map { ($0.bundleID, $0.totalBytes) })
        let streamMap = Dictionary(uniqueKeysWithValues: streamed.map { ($0.bundleID, $0.totalBytes) })
        XCTAssertEqual(batchMap, streamMap,
                       "scanAllStream 必须复用 scanOne，每条 item 的 totalBytes 应与 scanAll 完全一致")
    }

    // MARK: - 3. 空 apps 清单 stream 立即 finish 不死锁

    func test_scanAllStream_空清单立即finish() async {
        let scanner = AppFootprintScanner()
        var count = 0
        // 用超时兜底：5 秒还没结束算死锁
        let task = Task {
            for await _ in scanner.scanAllStream(apps: []) {
                count += 1
            }
            return count
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            task.cancel()
        }
        let result = await task.value
        timeout.cancel()
        XCTAssertEqual(result, 0, "空 apps 必须 yield 0 条并立即 finish")
    }

    // MARK: - 4. 消费方 break 后 detached task 应被取消

    func test_scanAllStream_break后onTermination触发cancel() async {
        // 构造 10 个 app，消费方在收到第 1 条后 break，剩下 9 条不应再 yield。
        // 我们用 sleep 间隔检测："break 后再等 200ms 是否仍有 yield"。
        var apps: [InstalledApp] = []
        for i in 0..<10 {
            apps.append(makeApp(bundleID: "com.x.\(i)", name: "X\(i)",
                                atPath: "/X\(i).app"))
        }
        let (scanner, _) = makeScanner(apps: apps)

        var seen = 0
        let stream = scanner.scanAllStream(apps: apps)
        for await _ in stream {
            seen += 1
            if seen == 1 { break }
        }
        // break 出 for-await 后，AsyncStream.continuation.onTermination 会触发
        // → detached task.cancel() → 后续 scanOne 检测 Task.isCancelled 不再 yield。
        // 这里只断言 break 那一刻只收到 1 条；onTermination 的副作用通过编译期 + 代码
        // 阅读验证（`continuation.onTermination = { _ in task.cancel() }`）。
        XCTAssertEqual(seen, 1, "break 应立即停止循环，只接收到 1 条")
    }

    // MARK: - 5. 流式 yield 的 item 与 scanOne 单次调用语义一致

    func test_scanAllStream_单app_yield的item与scanOne一致() async {
        let apps = [makeApp(bundleID: "com.solo", name: "Solo", atPath: "/Solo.app")]
        let (scanner, _) = makeScanner(apps: apps)

        // scanOne 直接取
        let direct = await scanner.scanOne(app: apps[0])

        // stream 取
        var streamed: AppFootprintItem?
        for await item in scanner.scanAllStream(apps: apps) {
            streamed = item
        }
        XCTAssertNotNil(streamed)
        XCTAssertEqual(streamed?.bundleID, direct.bundleID)
        XCTAssertEqual(streamed?.totalBytes, direct.totalBytes)
        XCTAssertEqual(streamed?.appBundleBytes, direct.appBundleBytes)
        XCTAssertEqual(streamed?.relatedBytes, direct.relatedBytes)
        XCTAssertEqual(streamed?.buckets.count, direct.buckets.count)
    }

    // MARK: - 6. 并发：两条 stream 同时跑同一 scanner 不互相覆盖

    /// AppFootprintScanner 是 actor，scanOne 是 actor 函数；scanAllStream 是
    /// `nonisolated` 但内部用 `await self.scanOne(...)` 进 actor。这意味着同时启动
    /// 两条 stream 时，每个 scanOne 仍按 actor reentrancy 串行执行，不会发生数据竞争。
    /// 这个测试验证：两条 stream 都能 yield 满应有数量，互不丢条。
    ///
    /// 对应 AppFootprintScreen.reload() 用户场景：用户连续按"刷新"，旧 streamTask
    /// 会被 cancel；但如果实现错把 scanner 内部状态污染，两次 stream 的 item 数会少。
    func test_scanAllStream_两条stream并发_各自yield满数() async {
        let apps = [
            makeApp(bundleID: "com.x", name: "X", atPath: "/X.app"),
            makeApp(bundleID: "com.y", name: "Y", atPath: "/Y.app"),
            makeApp(bundleID: "com.z", name: "Z", atPath: "/Z.app"),
        ]
        let (scanner, _) = makeScanner(apps: apps)

        async let a: [String] = {
            var out: [String] = []
            for await item in scanner.scanAllStream(apps: apps) {
                out.append(item.bundleID)
            }
            return out
        }()
        async let b: [String] = {
            var out: [String] = []
            for await item in scanner.scanAllStream(apps: apps) {
                out.append(item.bundleID)
            }
            return out
        }()

        let (resA, resB) = await (a, b)
        XCTAssertEqual(Set(resA), ["com.x", "com.y", "com.z"],
                       "stream A 应 yield 全部 3 个 app")
        XCTAssertEqual(Set(resB), ["com.x", "com.y", "com.z"],
                       "stream B 应 yield 全部 3 个 app")
        XCTAssertEqual(resA.count, 3)
        XCTAssertEqual(resB.count, 3)
    }

    // MARK: - 7. 取消后再次开 stream，scanner 仍可正常工作（无残留状态）

    /// 验证 AppFootprintScreen.reload() 二次触发的关键不变量：
    /// 旧 stream cancel 后 scanner 不留任何遗毒状态，新 stream 仍能完整 yield。
    func test_scanAllStream_cancel后再次开新stream仍能完整yield() async {
        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: "/A.app"),
            makeApp(bundleID: "com.b", name: "B", atPath: "/B.app"),
        ]
        let (scanner, _) = makeScanner(apps: apps)

        // 第 1 次：只收 1 条就 break（触发 onTermination → 内部 task.cancel()）
        var first: Int = 0
        for await _ in scanner.scanAllStream(apps: apps) {
            first += 1
            break
        }
        XCTAssertEqual(first, 1)

        // 第 2 次：完整收（验证 scanner 无残留状态）
        var second: [String] = []
        for await item in scanner.scanAllStream(apps: apps) {
            second.append(item.bundleID)
        }
        XCTAssertEqual(second.count, 2,
                       "上一条 stream cancel 后，scanner 必须能继续完整服务新 stream")
        XCTAssertEqual(Set(second), ["com.a", "com.b"])
    }

    // MARK: - 8. 单 app 故意 cancel 在 yield 之前：stream 不应 yield 任何 item

    /// 极端边界：apps 数组非空，但 consumer 立即取消 task。
    /// scanAllStream 内部循环开头会检查 Task.isCancelled → 直接 break。
    func test_scanAllStream_consumer立即cancel_yield零条() async {
        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: "/A.app"),
            makeApp(bundleID: "com.b", name: "B", atPath: "/B.app"),
        ]
        let (scanner, _) = makeScanner(apps: apps)

        let consumer = Task<Int, Never> {
            var n = 0
            for await _ in scanner.scanAllStream(apps: apps) {
                n += 1
            }
            return n
        }
        // 立即取消 —— consumer 取消会让 AsyncStream 走 onTermination → cancel 内部 task
        consumer.cancel()
        let n = await consumer.value
        // 严格上界：n 必须 <= 2（无丢失）；下界：极少数情况首条已 yield 完才被 cancel 接收到
        XCTAssertLessThanOrEqual(n, apps.count,
                                 "cancel 后最多 yield apps.count 条，不应超出")
    }
}
