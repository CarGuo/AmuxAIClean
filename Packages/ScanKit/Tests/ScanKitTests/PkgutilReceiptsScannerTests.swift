import XCTest
@testable import ScanKit

/// Mole 对齐 M3-T4：PkgutilReceiptsScanner 行为契约。
final class PkgutilReceiptsScannerTests: XCTestCase {

    // MARK: - joinVolumeLocation

    func test_joinVolumeLocation_根卷_空_location_返回空() {
        XCTAssertEqual(PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: ""), "")
    }

    func test_joinVolumeLocation_根卷_单段_location() {
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: "Library/Audio"),
            "/Library/Audio")
    }

    func test_joinVolumeLocation_去除_location_前后_slash() {
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: "/Library/X/"),
            "/Library/X")
    }

    func test_joinVolumeLocation_非根卷() {
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/Volumes/Ext", location: "data"),
            "/Volumes/Ext/data")
    }

    // MARK: - regexEscape

    func test_regexEscape_dot_必须转义() {
        XCTAssertEqual(PkgutilReceiptsScanner.regexEscape("com.adobe"), "com\\.adobe")
    }

    func test_regexEscape_无特殊字符_原样返回() {
        XCTAssertEqual(PkgutilReceiptsScanner.regexEscape("abc123"), "abc123")
    }

    // MARK: - Receipt.absolutePaths

    func test_absolutePaths_根卷() {
        let r = PkgutilReceiptsScanner.Receipt(
            pkgID: "com.x", installAbsoluteRoot: "",
            relativePaths: ["Library/Foo/a.dylib", "Library/Foo/b.plist"])
        XCTAssertEqual(r.absolutePaths,
                       ["/Library/Foo/a.dylib", "/Library/Foo/b.plist"])
    }

    func test_absolutePaths_有_location_前缀() {
        let r = PkgutilReceiptsScanner.Receipt(
            pkgID: "com.x", installAbsoluteRoot: "/Library/Audio",
            relativePaths: ["Plug-Ins/MyPlugin.component"])
        XCTAssertEqual(r.absolutePaths,
                       ["/Library/Audio/Plug-Ins/MyPlugin.component"])
    }

    // MARK: - receipts(matchingBundleIDPrefix:) 集成（fake runner）

    func test_receipts_按_prefix_过滤_并组装绝对路径() {
        let fake = FakePkgutilRunner(
            packages: ["com.adobe.AAM", "com.adobe.Reader", "com.other.X"],
            infos: [
                "com.adobe.AAM": .init(pkgID: "com.adobe.AAM", volume: "/",
                                       location: "Library/Application Support/Adobe",
                                       installTime: nil),
                "com.adobe.Reader": .init(pkgID: "com.adobe.Reader", volume: "/",
                                          location: "Applications",
                                          installTime: nil),
                "com.other.X": .init(pkgID: "com.other.X", volume: "/",
                                     location: "", installTime: nil)
            ],
            files: [
                "com.adobe.AAM": ["AAM/Updater.bundle", "AAM/AAM.log"],
                "com.adobe.Reader": ["Adobe Reader.app/Contents/Info.plist"],
                "com.other.X": ["usr/local/bin/x"]
            ])

        let scanner = PkgutilReceiptsScanner(runner: fake)
        let receipts = scanner.receipts(matchingBundleIDPrefix: "com.adobe")

        XCTAssertEqual(receipts.count, 2, "应只命中 2 条 com.adobe.*")
        let ids = Set(receipts.map(\.pkgID))
        XCTAssertEqual(ids, ["com.adobe.AAM", "com.adobe.Reader"])

        let aam = receipts.first(where: { $0.pkgID == "com.adobe.AAM" })!
        XCTAssertEqual(aam.absolutePaths.sorted(), [
            "/Library/Application Support/Adobe/AAM/AAM.log",
            "/Library/Application Support/Adobe/AAM/Updater.bundle"
        ])

        // 校验 runner 收到的 regex：句点要被转义，避免 com_adobe 等噪声
        XCTAssertEqual(fake.lastListRegex, "com\\.adobe.*")
    }

    func test_receipts_空_prefix_返回所有() {
        let fake = FakePkgutilRunner(
            packages: ["a", "b"],
            infos: [
                "a": .init(pkgID: "a", volume: "/", location: "", installTime: nil),
                "b": .init(pkgID: "b", volume: "/", location: "", installTime: nil)
            ],
            files: ["a": ["x"], "b": ["y"]])

        let receipts = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")
        XCTAssertEqual(receipts.count, 2)
        XCTAssertNil(fake.lastListRegex, "空 prefix 不应传 regex（pkgutil 走默认全量）")
    }

    func test_receipts_packageInfo_失败_条目跳过() {
        let fake = FakePkgutilRunner(
            packages: ["good", "bad"],
            infos: ["good": .init(pkgID: "good", volume: "/", location: "", installTime: nil)],
            files: ["good": ["x"], "bad": ["y"]])
        let receipts = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")
        XCTAssertEqual(receipts.map(\.pkgID), ["good"],
                       "packageInfo 返回 nil 时该条目应被跳过，不能崩")
    }
}

// MARK: - Fake runner

private final class FakePkgutilRunner: PkgutilRunning, @unchecked Sendable {
    let packages: [String]
    let infos: [String: PkgutilPackageInfo]
    let files: [String: [String]]
    var lastListRegex: String?

    init(packages: [String],
         infos: [String: PkgutilPackageInfo],
         files: [String: [String]]) {
        self.packages = packages
        self.infos = infos
        self.files = files
    }

    func listPackages(matchingRegex regex: String?) -> [String]? {
        lastListRegex = regex
        guard let regex else { return packages }
        let pattern = try? NSRegularExpression(pattern: "^" + regex + "$")
        return packages.filter { p in
            guard let pattern else { return true }
            let range = NSRange(p.startIndex..., in: p)
            return pattern.firstMatch(in: p, range: range) != nil
        }
    }

    func packageInfo(pkgID: String) -> PkgutilPackageInfo? {
        infos[pkgID]
    }

    func files(pkgID: String) -> [String]? {
        files[pkgID]
    }
}
