import XCTest
import Darwin
@testable import ScanKit

/// DerivedDataPerProjectScanner 行为契约。
///
/// 关注：
/// 1. 空/缺失的 DerivedData 根 → `[]`，不抛；
/// 2. 单/多工程子目录正确枚举；
/// 3. 工程名从 `MyApp-abc123xyz` 中正确剥出；
/// 4. sizeBytes 累加正确；
/// 5. modificationDate 已填且可用于排序；
/// 6. actor discover() 与 static detect() 行为一致。
final class DerivedDataPerProjectScannerTests: XCTestCase {

    // MARK: - Helpers

    /// 建一个临时 home 目录，返回 (homeURL, derivedDataRootURL)。
    /// derivedData 根**尚未创建**，由各 case 自行决定是否 mkdir。
    private func makeTempHome(file: StaticString = #filePath, line: UInt = #line) throws -> (home: URL, derivedData: URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DerivedDataPerProjectScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tmp)
        }
        let derived = tmp
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
        return (tmp, derived)
    }

    /// 在指定父目录下建一个 `<name>` 工程子目录，写入一个固定大小的占位文件，
    /// 并把目录 mtime 调到指定时间。
    @discardableResult
    private func makeProject(named name: String,
                             in parent: URL,
                             fileSize: Int,
                             mtime: Date) throws -> URL {
        let fm = FileManager.default
        let projectDir = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // 写一个固定大小的二进制文件，确保 sizeBytes > 0
        let payload = Data(repeating: 0xAB, count: fileSize)
        try payload.write(to: projectDir.appendingPathComponent("Build.bin"))
        // 调整子目录 mtime，便于排序断言
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: projectDir.path)
        return projectDir
    }

    private func makeHardLink(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func allocatedBytes(of file: URL) throws -> Int64 {
        let values = try file.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    // MARK: - Cases

    func test_detect_空home_返回空数组不抛() throws {
        let (home, _) = try makeTempHome()
        // 不创建 DerivedData 根，模拟用户从没装过 Xcode
        let hits = DerivedDataPerProjectScanner.detect(home: home)
        XCTAssertEqual(hits.count, 0, "DerivedData 根不存在应返回空，不应抛")
    }

    func test_detect_单工程_正确返回URL与size() throws {
        let (home, derived) = try makeTempHome()
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let projectURL = try makeProject(named: "MyApp-abc123xyz",
                                         in: derived,
                                         fileSize: 1024,
                                         mtime: Date(timeIntervalSince1970: 1_700_000_000))
        let hits = DerivedDataPerProjectScanner.detect(home: home)
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.url.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(hit.projectName, "MyApp")
        XCTAssertNotNil(hit.sizeBytes)
        XCTAssertGreaterThanOrEqual(hit.sizeBytes ?? 0, 1024,
                                    "1KB 占位文件至少要被累加进去（block-aligned 后可能更大）")
        XCTAssertNotNil(hit.modificationDate)
    }

    func test_detect_多工程_全部枚举() throws {
        let (home, derived) = try makeTempHome()
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try makeProject(named: "AppOne-aaa111",
                        in: derived, fileSize: 256,
                        mtime: Date(timeIntervalSince1970: 1_700_000_000))
        try makeProject(named: "AppTwo-bbb222",
                        in: derived, fileSize: 512,
                        mtime: Date(timeIntervalSince1970: 1_700_000_100))
        try makeProject(named: "AppThree-ccc333",
                        in: derived, fileSize: 768,
                        mtime: Date(timeIntervalSince1970: 1_700_000_200))
        // 干扰项 1：ModuleCache.noindex 应被跳过
        try FileManager.default.createDirectory(
            at: derived.appendingPathComponent("ModuleCache.noindex", isDirectory: true),
            withIntermediateDirectories: true
        )
        // 干扰项 2：Manifest.plist（普通文件）应被跳过
        try Data().write(to: derived.appendingPathComponent("Manifest.plist"))

        let hits = DerivedDataPerProjectScanner.detect(home: home)
        XCTAssertEqual(hits.count, 3, "ModuleCache.noindex 与 Manifest.plist 都不该计入")
        let names = Set(hits.map(\.projectName))
        XCTAssertEqual(names, ["AppOne", "AppTwo", "AppThree"])
    }

    func test_detect_工程名解析_去掉hash后缀() throws {
        // 单元化覆盖 parseProjectName 的核心分支
        XCTAssertEqual(
            DerivedDataPerProjectScanner.parseProjectName(from: "MyApp-abc123xyz"),
            "MyApp"
        )
        // 工程名本身含 `-` 时，只剥最后一段
        XCTAssertEqual(
            DerivedDataPerProjectScanner.parseProjectName(from: "My-Cool-App-abc123xyz"),
            "My-Cool-App"
        )
        // 无 `-` 的异常命名 → 兜底原样返回
        XCTAssertEqual(
            DerivedDataPerProjectScanner.parseProjectName(from: "WeirdNameNoDash"),
            "WeirdNameNoDash"
        )
        // `-` 在最前缀（前缀为空）→ 也兜底原样返回，避免 projectName=""
        XCTAssertEqual(
            DerivedDataPerProjectScanner.parseProjectName(from: "-onlyhash"),
            "-onlyhash"
        )
    }

    func test_detect_mtime可用于排序() throws {
        let (home, derived) = try makeTempHome()
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let mid = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        try makeProject(named: "Old-aaa", in: derived, fileSize: 100, mtime: old)
        try makeProject(named: "Recent-ccc", in: derived, fileSize: 100, mtime: recent)
        try makeProject(named: "Mid-bbb", in: derived, fileSize: 100, mtime: mid)

        let hits = DerivedDataPerProjectScanner.detect(home: home)
        XCTAssertEqual(hits.count, 3)
        let sorted = hits.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        XCTAssertEqual(sorted.map(\.projectName), ["Old", "Mid", "Recent"],
                       "modificationDate 必须真实填入，且能用于稳定排序")
    }

    func test_discover_actor入口_与detect一致() async throws {
        let (home, derived) = try makeTempHome()
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try makeProject(named: "AlphaApp-zzz999",
                        in: derived, fileSize: 333,
                        mtime: Date(timeIntervalSince1970: 1_700_000_000))
        let scanner = DerivedDataPerProjectScanner()
        let hits = await scanner.discover(home: home)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.projectName, "AlphaApp")
    }

    /// v2026.07.16: shared Xcode caches are not projects merely because they are first-level
    /// directories. The aggregate snapshot still counts their bytes, while the project
    /// projection is driven by structural identity rather than a product-name deny-list.
    func test_snapshot_共享noindex缓存计入整根但不伪装成项目() throws {
        let (home, derived) = try makeTempHome()
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        let project = try makeProject(
            named: "RealProject-abc123",
            in: derived,
            fileSize: 1_024,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        for cacheName in ["CompilationCache.noindex", "SDKStatCaches.noindex"] {
            let cache = derived.appendingPathComponent(cacheName, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(repeating: 0xCD, count: 2_048).write(
                to: cache.appendingPathComponent("payload.bin")
            )
        }

        let snapshot = DerivedDataPerProjectScanner.detectSnapshot(home: home)

        XCTAssertTrue(snapshot.rootExists)
        XCTAssertEqual(snapshot.projects.hits.map(\.url), [project])
        XCTAssertEqual(snapshot.projects.hits.map(\.projectName), ["RealProject"])
        XCTAssertEqual(snapshot.sharedDirectoryCount, 2)
        let projectBytes = try XCTUnwrap(snapshot.projects.hits.first?.sizeBytes)
        let rootBytes = try XCTUnwrap(snapshot.rootSizeBytes)
        XCTAssertGreaterThan(rootBytes, projectBytes, "整根容量必须包含共享缓存，但项目卡不能展示它们")
        XCTAssertEqual(
            snapshot.retainedHardlinkIdentityCount,
            0,
            "v2026.07.17 性能合同：普通单链接文件必须立即计量，不能全部驻留 inode 归属表"
        )
    }

    /// **v2026.07.16 root-cause regression:** one physical inode can have pathnames in a
    /// shared Xcode cache and multiple project directories. The root counts it once, while
    /// project attribution is deterministic and exclusive so project rows cannot sum to an
    /// invented multiple of the physical allocation.
    func test_snapshot_跨共享目录与两个工程的hardlink_整根只计一次且归属唯一() throws {
        let (home, derived) = try makeTempHome()
        let shared = derived.appendingPathComponent("CompilationCache.noindex", isDirectory: true)
        let alpha = derived.appendingPathComponent("Alpha-aaa", isDirectory: true)
        let zulu = derived.appendingPathComponent("Zulu-zzz", isDirectory: true)
        for directory in [shared, alpha, zulu] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let source = shared.appendingPathComponent("physical.bin")
        try Data(repeating: 0xA5, count: 4_096).write(to: source)
        try makeHardLink(from: source, to: zulu.appendingPathComponent("zulu-link.bin"))
        try makeHardLink(from: source, to: alpha.appendingPathComponent("alpha-link.bin"))
        let expectedPhysicalBytes = try allocatedBytes(of: source)
        XCTAssertGreaterThan(expectedPhysicalBytes, 0)

        let snapshot = DerivedDataPerProjectScanner.detectSnapshot(home: home)
        let alphaBytes = try XCTUnwrap(
            snapshot.projects.hits.first { $0.projectName == "Alpha" }?.sizeBytes
        )
        let zuluBytes = try XCTUnwrap(
            snapshot.projects.hits.first { $0.projectName == "Zulu" }?.sizeBytes
        )

        XCTAssertEqual(snapshot.rootSizeBytes, expectedPhysicalBytes,
                       "三个 pathname 共享一个 inode，整根只能计一份物理分配")
        XCTAssertEqual(alphaBytes, expectedPhysicalBytes,
                       "跨工程 hardlink 固定归属字典序最小的工程目录")
        XCTAssertEqual(zuluBytes, 0)
        XCTAssertEqual(
            snapshot.projects.hits.compactMap(\.sizeBytes).reduce(0, +),
            expectedPhysicalBytes,
            "project buckets 之间不得重复归属同一物理 inode"
        )
        XCTAssertEqual(snapshot.sharedDirectoryCount, 1)
        XCTAssertEqual(
            snapshot.retainedHardlinkIdentityCount,
            1,
            "真正跨路径的 hardlink 仍必须保留一条精确 inode 归属记录"
        )
    }

    func test_detect_infoPlist元数据可识别非hash工程目录() throws {
        let (home, derived) = try makeTempHome()
        let project = derived.appendingPathComponent("CustomLocation", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["WorkspacePath": "/tmp/Custom.xcworkspace"]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: metadata,
            format: .binary,
            options: 0
        )
        try plist.write(to: project.appendingPathComponent("info.plist"))

        let hits = DerivedDataPerProjectScanner.detect(home: home, includeSizes: false)

        XCTAssertEqual(hits.map(\.url), [project])
        XCTAssertEqual(hits.map(\.projectName), ["CustomLocation"])
    }

    func test_snapshot_symlinkedDerivedDataRootPropagatesProjectSubtreeIncompleteToProjectHit() throws {
        let (home, derivedLink) = try makeTempHome()
        let externalDerived = home.appendingPathComponent("ExternalDerivedDataTarget", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDerived, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: derivedLink.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: derivedLink, withDestinationURL: externalDerived)

        _ = try makeProject(
            named: "Healthy-aaa111",
            in: externalDerived,
            fileSize: 4_096,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let broken = try makeProject(
            named: "Broken-bbb222",
            in: externalDerived,
            fileSize: 4_096,
            mtime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let lockedSubdir = broken.appendingPathComponent("LockedSubdir", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedSubdir, withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 4_096).write(to: lockedSubdir.appendingPathComponent("secret.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedSubdir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedSubdir.path)
        }

        // Skip permission assertion if running as root (uid 0 bypasses 0o000).
        guard geteuid() != 0 else { return }

        let snapshot = DerivedDataPerProjectScanner.detectSnapshot(home: home)
        let healthyHit = try XCTUnwrap(snapshot.projects.hits.first { $0.projectName == "Healthy" })
        let brokenHit = try XCTUnwrap(snapshot.projects.hits.first { $0.projectName == "Broken" })

        XCTAssertNotNil(healthyHit.sizeBytes, "Healthy project under symlinked DerivedData root should retain its measured size")
        XCTAssertNil(brokenHit.sizeBytes, "Project with an incomplete descendant under symlinked DerivedData root must have nil sizeBytes rather than a truncated byte count")
        XCTAssertFalse(snapshot.projects.isComplete)
    }
}
