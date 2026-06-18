import XCTest
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
}
