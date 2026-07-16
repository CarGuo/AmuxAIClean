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

    // MARK: - Default runner owned-child 边界（仅注入无副作用 fixture）

    /// v2026.07.16：pkgutil 的 stderr 可能包含 warning，但 pkgID/路径协议只存在 stdout。
    /// 两路必须分离，避免诊断文字被当成可删除路径。
    func test_defaultRunner_只解析stdout且保留硬编码参数形状() {
        let recorder = PkgutilArgumentsRecorder()
        let runner = DefaultPkgutilRunner { args in
            recorder.store(args)
            return makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "com.example.one\ncom.example.two\n",
                stderr: "pkgutil diagnostic must not be parsed\n"
            )
        }

        XCTAssertEqual(
            runner.listPackages(matchingRegex: "com\\.example.*"),
            ["com.example.one", "com.example.two"]
        )
        XCTAssertEqual(recorder.value, ["--pkgs=com\\.example.*"])
    }

    /// 大 stdout/stderr 同时写入必须持续排空；fixture 只运行 `/bin/sh`，不调用真实
    /// pkgutil、不读取 receipt 或用户目录。
    func test_defaultRunner_大files输出不会pipe死锁且stderr不混入路径() {
        let script = """
        (i=0; while [ $i -lt 10000 ]; do printf 'Library/file-%05d\\n' "$i"; i=$((i+1)); done) &
        (i=0; while [ $i -lt 10000 ]; do printf 'diagnostic-%05d\\n' "$i" >&2; i=$((i+1)); done) &
        wait
        """
        let runner = DefaultPkgutilRunner { _ in
            OwnedChildProcessExecutor.run(
                path: "/bin/sh",
                arguments: ["-c", script],
                timeout: 5,
                outputLimitPerStream: DefaultPkgutilRunner.outputLimitPerStream
            )
        }

        let files = runner.files(pkgID: "fixture")
        XCTAssertEqual(files?.count, 10_000)
        XCTAssertEqual(files?.first, "Library/file-00000")
        XCTAssertEqual(files?.last, "Library/file-09999")
        XCTAssertFalse(files?.contains(where: { $0.hasPrefix("diagnostic-") }) ?? true)
    }

    func test_defaultRunner_launch非零timeout继续返回nil() {
        let failures: [OwnedChildProcessExecutor.TerminalState] = [
            .launchFailed(message: "fixture launch failure"),
            .exited(status: 7 << 8),
            .timedOut(sentSIGKILL: false, reapTransferred: false),
            .notOwned,
        ]
        for terminal in failures {
            let runner = DefaultPkgutilRunner { _ in
                makeOwnedResult(terminal: terminal, stdout: "must-not-parse\n")
            }
            XCTAssertNil(runner.files(pkgID: "fixture"), "失败终态必须返回 nil: \(terminal)")
        }
    }

    /// 截断的路径列表不是可信前缀；即使命令 exit 0 也必须 fail closed。
    func test_defaultRunner_stdout截断或未到EOF返回nil() {
        let truncated = DefaultPkgutilRunner { _ in
            makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "partial/path\n",
                stdoutWasTruncated: true
            )
        }
        XCTAssertNil(truncated.files(pkgID: "fixture"))

        let incomplete = DefaultPkgutilRunner { _ in
            makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "partial/path\n",
                readersReachedEOF: false
            )
        }
        XCTAssertNil(incomplete.files(pkgID: "fixture"))
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

private func makeOwnedResult(
    terminal: OwnedChildProcessExecutor.TerminalState,
    stdout: String = "",
    stderr: String = "",
    stdoutWasTruncated: Bool = false,
    stderrWasTruncated: Bool = false,
    readersReachedEOF: Bool = true
) -> OwnedChildProcessExecutor.ExecutionResult {
    OwnedChildProcessExecutor.ExecutionResult(
        terminal: terminal,
        stdout: stdout,
        stderr: stderr,
        output: stdout + stderr,
        stdoutWasTruncated: stdoutWasTruncated,
        stderrWasTruncated: stderrWasTruncated,
        readersReachedEOF: readersReachedEOF
    )
}

private final class PkgutilArgumentsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func store(_ arguments: [String]) {
        lock.lock()
        storage = arguments
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
