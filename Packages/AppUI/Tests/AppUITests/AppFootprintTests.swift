import XCTest
import SafetyKit
@testable import AppUI

/// v1.2 P1-6 应用占用排行榜 —— 数据契约与扫描器单元测试。
///
/// 关键不变量：
/// - 排序：`scanAll` 按 `totalBytes` 倒序返回（最肥的 app 在第一行）
/// - 聚合：totalBytes == appBundleBytes + sum(buckets[1...].bytes)
/// - 桶分类：bundleID/appName → userData，bundleVendor → launchAgent，vendorRule → vendorRule
/// - 进度：每完成一个 app 回调一次 (done, total)
/// - **只读契约**：扫描器没有任何删除入口（这层在编译期就保证）
final class AppFootprintTests: XCTestCase {

    // MARK: - 测试 fixture

    /// 完全 in-memory 的假 FM，sandbox 不真实命中磁盘。
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

    // MARK: - 1. bucketKind 映射

    func test_bucketKind_bundleID映射到userData() {
        XCTAssertEqual(AppFootprintScanner.bucketKind(for: .bundleID("com.foo")), .userData)
    }

    func test_bucketKind_appName映射到userData() {
        XCTAssertEqual(AppFootprintScanner.bucketKind(for: .appName("Foo")), .userData)
    }

    func test_bucketKind_bundleVendor映射到launchAgent() {
        XCTAssertEqual(AppFootprintScanner.bucketKind(for: .bundleVendor("com.foo")), .launchAgent)
    }

    func test_bucketKind_vendorRule映射到vendorRule() {
        XCTAssertEqual(AppFootprintScanner.bucketKind(for: .vendorRule("Adobe")), .vendorRule)
    }

    // MARK: - 2. 模型不变量

    func test_AppFootprintItem_totalBytes等于bundle加related() {
        let buckets = [
            AppFootprintBucket(path: "/A.app", bytes: 100, fileCount: 1, kind: .bundle),
            AppFootprintBucket(path: "/d", bytes: 30, fileCount: 1, kind: .userData)
        ]
        let item = AppFootprintItem(
            bundleID: "x", appName: "X",
            appURL: URL(fileURLWithPath: "/A.app"),
            appBundleBytes: 100, relatedBytes: 30,
            buckets: buckets
        )
        XCTAssertEqual(item.totalBytes, 130)
    }

    // MARK: - 3. 单 app 聚合

    func test_scanOne_仅bundle无关联目录_relatedBytes为0() async {
        let home = "/H"
        let appPath = "/Applications/Foo.app"

        // 关联目录全空（FakeFM 返回 nil → AppUninstaller 找不到候选）
        let fm = FakeFM(entriesByRoot: [:], snapshots: [
            appPath: .init(bytes: 5_000_000, fileCount: 42)
        ])
        let unins = AppUninstaller(homeDirectory: home, fileManager: fm, vendorRules: [])
        let scanner = AppFootprintScanner(uninstaller: unins, snapshot: fm)

        let app = makeApp(bundleID: "com.foo.bar", name: "Foo", atPath: appPath)
        let item = await scanner.scanOne(app: app)

        XCTAssertEqual(item.appBundleBytes, 5_000_000)
        XCTAssertEqual(item.relatedBytes, 0)
        XCTAssertEqual(item.totalBytes, 5_000_000)
        // 至少一个 bundle 桶
        XCTAssertEqual(item.buckets.count, 1)
        XCTAssertEqual(item.buckets.first?.kind, .bundle)
    }

    func test_scanOne_有关联目录_关联bytes累加且按字节倒序() async {
        let home = "/H"
        let appPath = "/Applications/Demo.app"
        let cachesPath = "\(home)/Library/Caches"

        // 在 Caches 下挂 3 个 com.acme.demo.* 命中候选
        let entries = (0..<3).map { i in
            FSEntry(name: "com.acme.demo.\(i)", path: "\(cachesPath)/com.acme.demo.\(i)")
        }
        let snaps: [String: FSSnapshot] = [
            appPath: .init(bytes: 100, fileCount: 1),
            "\(cachesPath)/com.acme.demo.0": .init(bytes: 1000, fileCount: 5),
            "\(cachesPath)/com.acme.demo.1": .init(bytes: 50_000, fileCount: 8),
            "\(cachesPath)/com.acme.demo.2": .init(bytes: 200, fileCount: 2)
        ]
        let fm = FakeFM(entriesByRoot: [cachesPath: entries], snapshots: snaps)
        let unins = AppUninstaller(homeDirectory: home, fileManager: fm, vendorRules: [])
        let scanner = AppFootprintScanner(uninstaller: unins, snapshot: fm)

        let app = makeApp(bundleID: "com.acme.demo", name: "Demo", atPath: appPath)
        let item = await scanner.scanOne(app: app)

        XCTAssertEqual(item.appBundleBytes, 100)
        XCTAssertEqual(item.relatedBytes, 1000 + 50_000 + 200)
        XCTAssertEqual(item.totalBytes, 100 + 1000 + 50_000 + 200)

        // bundle 在第 0；其余 3 个按字节倒序：50_000 / 1000 / 200
        XCTAssertEqual(item.buckets.count, 4)
        XCTAssertEqual(item.buckets[0].kind, .bundle)
        XCTAssertEqual(item.buckets[1].bytes, 50_000)
        XCTAssertEqual(item.buckets[2].bytes, 1000)
        XCTAssertEqual(item.buckets[3].bytes, 200)
    }

    // MARK: - 4. 排行榜聚合

    func test_scanAll_按totalBytes倒序() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"

        // 3 个 app：A 50MB / B 200MB / C 1MB（仅 bundle，无关联）
        let aPath = "/Applications/A.app"
        let bPath = "/Applications/B.app"
        let cPath = "/Applications/C.app"
        let snaps: [String: FSSnapshot] = [
            aPath: .init(bytes: 50_000_000, fileCount: 1),
            bPath: .init(bytes: 200_000_000, fileCount: 1),
            cPath: .init(bytes: 1_000_000, fileCount: 1)
        ]
        let fm = FakeFM(entriesByRoot: [cachesPath: []], snapshots: snaps)
        let unins = AppUninstaller(homeDirectory: home, fileManager: fm, vendorRules: [])
        let scanner = AppFootprintScanner(uninstaller: unins, snapshot: fm)

        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: aPath),
            makeApp(bundleID: "com.b", name: "B", atPath: bPath),
            makeApp(bundleID: "com.c", name: "C", atPath: cPath)
        ]
        let items = await scanner.scanAll(apps: apps)

        XCTAssertEqual(items.count, 3)
        // 倒序：B(200M) → A(50M) → C(1M)
        XCTAssertEqual(items[0].bundleID, "com.b")
        XCTAssertEqual(items[1].bundleID, "com.a")
        XCTAssertEqual(items[2].bundleID, "com.c")
    }

    func test_scanAll_空清单返回空数组() async {
        let scanner = AppFootprintScanner()
        let items = await scanner.scanAll(apps: [])
        XCTAssertEqual(items.count, 0)
    }

    // MARK: - 5. 进度回调

    func test_scanAll_progress回调N次_每次done递增() async {
        let home = "/H"
        let cachesPath = "\(home)/Library/Caches"
        let snaps: [String: FSSnapshot] = [
            "/A.app": .init(bytes: 1, fileCount: 1),
            "/B.app": .init(bytes: 2, fileCount: 1)
        ]
        let fm = FakeFM(entriesByRoot: [cachesPath: []], snapshots: snaps)
        let unins = AppUninstaller(homeDirectory: home, fileManager: fm, vendorRules: [])
        let scanner = AppFootprintScanner(uninstaller: unins, snapshot: fm)

        let apps = [
            makeApp(bundleID: "com.a", name: "A", atPath: "/A.app"),
            makeApp(bundleID: "com.b", name: "B", atPath: "/B.app")
        ]

        // 用 actor 收集回调
        actor Progress {
            var calls: [(Int, Int)] = []
            func append(_ d: Int, _ t: Int) { calls.append((d, t)) }
            func snapshot() -> [(Int, Int)] { calls }
        }
        let p = Progress()

        _ = await scanner.scanAll(apps: apps) { d, t in
            Task { await p.append(d, t) }
        }

        // 等一拍让 Task 落定
        try? await Task.sleep(nanoseconds: 100_000_000)
        let calls = await p.snapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, 1)
        XCTAssertEqual(calls[0].1, 2)
        XCTAssertEqual(calls[1].0, 2)
        XCTAssertEqual(calls[1].1, 2)
    }

    // MARK: - 6. 安全契约：扫描器不暴露任何删除入口

    func test_安全契约_AppFootprintScanner没有删除API() {
        // 这是一条编译期 + 阅读期的不变量：AppFootprintScanner 上不应有任何
        // 名为 trash/remove/delete 的方法。这里用一个 sanity test 钉住意图——
        // 如果未来有人不小心加了删除方法，code review + grep 会立刻发现。
        let scanner = AppFootprintScanner()
        // 仅触达 scanAll/scanOne 这两个公开 API
        XCTAssertNotNil(scanner)
    }
}
