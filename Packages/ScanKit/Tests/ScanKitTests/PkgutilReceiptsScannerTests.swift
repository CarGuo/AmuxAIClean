import XCTest
@testable import ScanKit

/// Mole 对齐 M3-T4：PkgutilReceiptsScanner 行为契约。
final class PkgutilReceiptsScannerTests: XCTestCase {

    // MARK: - joinVolumeLocation

    func test_joinVolumeLocation_根卷_空_location_返回canonical根() {
        XCTAssertEqual(PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: ""), "/")
        XCTAssertEqual(PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: "/"), "/")
    }

    func test_joinVolumeLocation_根卷_单段_location() {
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: "Library/Audio"),
            "/Library/Audio")
    }

    func test_joinVolumeLocation_绝对location或非canonical根_failClosed() {
        XCTAssertNil(PkgutilReceiptsScanner.joinVolumeLocation(
            volume: "/",
            location: "/Library/X"
        ))
        XCTAssertNil(PkgutilReceiptsScanner.joinVolumeLocation(
            volume: "Volumes/Ext",
            location: "data"
        ))
        XCTAssertNil(PkgutilReceiptsScanner.joinVolumeLocation(
            volume: "/Volumes/../private",
            location: "data"
        ))
    }

    func test_joinVolumeLocation_非根卷() {
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/Volumes/Ext", location: "data"),
            "/Volumes/Ext/data")
        XCTAssertEqual(
            PkgutilReceiptsScanner.joinVolumeLocation(volume: "/", location: "Library/Apple/"),
            "/Library/Apple")
    }

    // MARK: - regexEscape

    func test_regexEscape_dot_必须转义() {
        XCTAssertEqual(PkgutilReceiptsScanner.regexEscape("com.adobe"), "com\\.adobe")
    }

    func test_regexEscape_无特殊字符_原样返回() {
        XCTAssertEqual(PkgutilReceiptsScanner.regexEscape("abc123"), "abc123")
    }

    // MARK: - Receipt.absolutePaths

    func test_absolutePaths_根卷() throws {
        let r = try XCTUnwrap(PkgutilReceiptsScanner.Receipt(
            pkgID: "com.x", installAbsoluteRoot: "/",
            relativePaths: ["Library/Foo/a.dylib", "Library/Foo/b.plist"]))
        XCTAssertEqual(r.absolutePaths,
                       ["/Library/Foo/a.dylib", "/Library/Foo/b.plist"])
    }

    func test_absolutePaths_有_location_前缀() throws {
        let r = try XCTUnwrap(PkgutilReceiptsScanner.Receipt(
            pkgID: "com.x", installAbsoluteRoot: "/Library/Audio",
            relativePaths: ["Plug-Ins/MyPlugin.component"]))
        XCTAssertEqual(r.absolutePaths,
                       ["/Library/Audio/Plug-Ins/MyPlugin.component"])
    }

    /// v2026.07.18: `Receipt` itself is the last trust boundary. Alternate runners and tests must
    /// not be able to manufacture an escaping `absolutePaths` projection.
    func test_receiptInitializer_拒绝绝对空点与traversal路径() {
        let invalid = ["", ".", "..", "/etc/passwd", "Library/../private", "Library//item"]
        for relativePath in invalid {
            XCTAssertNil(PkgutilReceiptsScanner.Receipt(
                pkgID: "com.x",
                installAbsoluteRoot: "/",
                relativePaths: [relativePath]
            ), "must reject \(relativePath)")
        }
        XCTAssertNil(PkgutilReceiptsScanner.Receipt(
            pkgID: "com.x",
            installAbsoluteRoot: "relative/root",
            relativePaths: ["item"]
        ))
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
        let result = scanner.receipts(matchingBundleIDPrefix: "com.adobe")
        let receipts = result.receipts

        XCTAssertEqual(receipts.count, 2, "应只命中 2 条 com.adobe.*")
        XCTAssertTrue(result.isComplete)
        let ids = Set(receipts.map(\.pkgID))
        XCTAssertEqual(ids, ["com.adobe.AAM", "com.adobe.Reader"])

        let aam = receipts.first(where: { $0.pkgID == "com.adobe.AAM" })!
        XCTAssertEqual(aam.absolutePaths.sorted(), [
            "/Library/Application Support/Adobe/AAM/AAM.log",
            "/Library/Application Support/Adobe/AAM/Updater.bundle"
        ])

        // 校验 runner 收到的 regex：锚定 exact-or-dot-descendant，不能误收相似厂商名。
        XCTAssertEqual(fake.lastListRegex, "^com\\.adobe(\\..*)?$")
    }

    /// v2026.07.18：外部命令的 regexp 只是查询优化，不能成为卸载关联的唯一边界。
    /// 即使 runner 忽略过滤并返回近似前缀，扫描器也只能接收 exact/dot descendant。
    func test_receipts_生产结果再次校验_reverseDNS_段边界() {
        let packages = [
            "com.adobe",
            "com.adobe.Reader",
            "com.adobeevil.Reader",
            "xcom.adobe.Reader",
        ]
        let infos = Dictionary(uniqueKeysWithValues: packages.map {
            ($0, PkgutilPackageInfo(pkgID: $0, volume: "/", location: "", installTime: nil))
        })
        let files = Dictionary(uniqueKeysWithValues: packages.map { ($0, ["Library/\($0)"]) })
        let fake = FakePkgutilRunner(
            packages: packages,
            infos: infos,
            files: files,
            honorsRegex: false
        )

        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "com.adobe")

        XCTAssertEqual(result.receipts.map(\.pkgID), ["com.adobe", "com.adobe.Reader"])
        XCTAssertEqual(fake.lastListRegex, "^com\\.adobe(\\..*)?$")
    }

    func test_receipts_空_prefix_返回所有() {
        let fake = FakePkgutilRunner(
            packages: ["a", "b"],
            infos: [
                "a": .init(pkgID: "a", volume: "/", location: "", installTime: nil),
                "b": .init(pkgID: "b", volume: "/", location: "", installTime: nil)
            ],
            files: ["a": ["x"], "b": ["y"]])

        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")
        XCTAssertEqual(result.receipts.count, 2)
        XCTAssertTrue(result.incompleteIssues.isEmpty)
        XCTAssertNil(fake.lastListRegex, "空 prefix 不应传 regex（pkgutil 走默认全量）")
    }

    func test_receipts_packageInfo_失败_条目跳过且保留精确缺口() {
        let fake = FakePkgutilRunner(
            packages: ["good", "bad"],
            infos: ["good": .init(pkgID: "good", volume: "/", location: "", installTime: nil)],
            files: ["good": ["x"], "bad": ["y"]])
        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")
        XCTAssertEqual(result.receipts.map(\.pkgID), ["good"],
                       "packageInfo typed failure 时该条目应被跳过，不能崩")
        XCTAssertEqual(result.incompleteIssues, [
            .init(stage: .packageInfo, pkgID: "bad", reason: .unexpectedFailure)
        ])
    }

    func test_receipts_files失败_不生成空清单且只污染对应receipt() {
        let fake = FakePkgutilRunner(
            packages: ["good", "bad"],
            infos: [
                "good": .init(pkgID: "good", volume: "/", location: "", installTime: nil),
                "bad": .init(pkgID: "bad", volume: "/", location: "", installTime: nil)
            ],
            files: ["good": ["x"]],
            fileFailures: ["bad": .outputTruncated]
        )

        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")

        XCTAssertEqual(result.receipts.map(\.pkgID), ["good"])
        XCTAssertEqual(result.incompleteIssues, [
            .init(stage: .files, pkgID: "bad", reason: .outputTruncated)
        ])
    }

    func test_receipts_非法root或payload不发布partialReceipt且保留typed缺口() {
        let fake = FakePkgutilRunner(
            packages: ["bad.root", "bad.path", "good"],
            infos: [
                "bad.root": .init(
                    pkgID: "bad.root",
                    volume: "relative",
                    location: "Applications",
                    installTime: nil
                ),
                "bad.path": .init(
                    pkgID: "bad.path",
                    volume: "/",
                    location: "Applications",
                    installTime: nil
                ),
                "good": .init(
                    pkgID: "good",
                    volume: "/",
                    location: "Applications",
                    installTime: nil
                ),
            ],
            files: [
                "bad.root": ["Demo.app"],
                "bad.path": ["Demo.app", "../Users/tester/Documents"],
                "good": ["Good.app"],
            ]
        )

        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "")

        XCTAssertEqual(result.receipts.map(\.pkgID), ["good"])
        XCTAssertEqual(result.receipts.first?.absolutePaths, ["/Applications/Good.app"])
        XCTAssertEqual(Set(result.incompleteIssues), [
            .init(stage: .receiptValidation, pkgID: "bad.root", reason: .invalidInstallRoot),
            .init(stage: .receiptValidation, pkgID: "bad.path", reason: .invalidRelativePath),
        ])
    }

    func test_receipts_packageList失败_空命中不能被解释为可信空() {
        let fake = FakePkgutilRunner(
            packages: [],
            infos: [:],
            files: [:],
            listFailure: .timedOut
        )

        let result = PkgutilReceiptsScanner(runner: fake)
            .receipts(matchingBundleIDPrefix: "com.acme")

        XCTAssertTrue(result.receipts.isEmpty)
        XCTAssertEqual(result.incompleteIssues, [
            .init(stage: .packageList, pkgID: nil, reason: .timedOut)
        ])
    }

    // MARK: - Default runner owned-child 边界（仅注入无副作用 fixture）

    /// v2026.07.16：pkgutil 的 stderr 可能包含 warning，但 pkgID/路径协议只存在 stdout。
    /// 两路必须分离，避免诊断文字被当成可删除路径。
    func test_defaultRunner_只解析stdout且保留硬编码参数形状() throws {
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
            try runner.listPackages(matchingRegex: "com\\.example.*"),
            ["com.example.one", "com.example.two"]
        )
        XCTAssertEqual(recorder.value, ["--pkgs=com\\.example.*"])
    }

    func test_defaultRunner_packageInfo缺少root字段不得默认成根卷() {
        let runner = DefaultPkgutilRunner { _ in
            makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "package-id: com.example.demo\nversion: 1\n"
            )
        }

        XCTAssertThrowsError(try runner.packageInfo(pkgID: "com.example.demo")) { error in
            XCTAssertEqual(error as? PkgutilCommandFailure, .incompleteOutput)
        }
    }

    /// 大 stdout/stderr 同时写入必须持续排空；fixture 只运行 `/bin/sh`，不调用真实
    /// pkgutil、不读取 receipt 或用户目录。
    func test_defaultRunner_大files输出不会pipe死锁且stderr不混入路径() throws {
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

        let files = try runner.files(pkgID: "fixture")
        XCTAssertEqual(files.count, 10_000)
        XCTAssertEqual(files.first, "Library/file-00000")
        XCTAssertEqual(files.last, "Library/file-09999")
        XCTAssertFalse(files.contains(where: { $0.hasPrefix("diagnostic-") }))
    }

    func test_defaultRunner_所有失败终态映射为精确typedReason() {
        let failures: [(OwnedChildProcessExecutor.TerminalState, PkgutilCommandFailure)] = [
            (.launchFailed(message: "fixture launch failure"), .launchFailed),
            (.exited(status: 7 << 8), .nonZeroExit(7)),
            (.timedOut(sentSIGKILL: false, reapTransferred: false), .timedOut),
            (.cancelled(sentSIGKILL: false, reapTransferred: false), .cancelled),
            (.notOwned, .processOwnershipLost),
        ]
        for (terminal, expected) in failures {
            let runner = DefaultPkgutilRunner { _ in
                makeOwnedResult(terminal: terminal, stdout: "must-not-parse\n")
            }
            XCTAssertThrowsError(try runner.files(pkgID: "fixture")) { error in
                XCTAssertEqual(error as? PkgutilCommandFailure, expected)
            }
        }
    }

    /// 截断的路径列表不是可信前缀；即使命令 exit 0 也必须 fail closed。
    func test_defaultRunner_stdout截断或未到EOF返回精确typedReason() {
        let truncated = DefaultPkgutilRunner { _ in
            makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "partial/path\n",
                stdoutWasTruncated: true
            )
        }
        XCTAssertThrowsError(try truncated.files(pkgID: "fixture")) { error in
            XCTAssertEqual(error as? PkgutilCommandFailure, .outputTruncated)
        }

        let incomplete = DefaultPkgutilRunner { _ in
            makeOwnedResult(
                terminal: .exited(status: 0),
                stdout: "partial/path\n",
                readersReachedEOF: false
            )
        }
        XCTAssertThrowsError(try incomplete.files(pkgID: "fixture")) { error in
            XCTAssertEqual(error as? PkgutilCommandFailure, .incompleteOutput)
        }
    }
}

// MARK: - Fake runner

private final class FakePkgutilRunner: PkgutilRunning, @unchecked Sendable {
    let packages: [String]
    let infos: [String: PkgutilPackageInfo]
    let files: [String: [String]]
    let listFailure: PkgutilCommandFailure?
    let infoFailures: [String: PkgutilCommandFailure]
    let fileFailures: [String: PkgutilCommandFailure]
    let honorsRegex: Bool
    var lastListRegex: String?

    init(packages: [String],
         infos: [String: PkgutilPackageInfo],
         files: [String: [String]],
         listFailure: PkgutilCommandFailure? = nil,
         infoFailures: [String: PkgutilCommandFailure] = [:],
         fileFailures: [String: PkgutilCommandFailure] = [:],
         honorsRegex: Bool = true) {
        self.packages = packages
        self.infos = infos
        self.files = files
        self.listFailure = listFailure
        self.infoFailures = infoFailures
        self.fileFailures = fileFailures
        self.honorsRegex = honorsRegex
    }

    func listPackages(matchingRegex regex: String?) throws -> [String] {
        lastListRegex = regex
        if let listFailure { throw listFailure }
        guard honorsRegex, let regex else { return packages }
        // Mirror production regexp semantics. Do not add test-only anchors that can hide a
        // boundary bug in the expression passed to pkgutil.
        let pattern = try? NSRegularExpression(pattern: regex)
        return packages.filter { p in
            guard let pattern else { return true }
            let range = NSRange(p.startIndex..., in: p)
            return pattern.firstMatch(in: p, range: range) != nil
        }
    }

    func packageInfo(pkgID: String) throws -> PkgutilPackageInfo {
        if let failure = infoFailures[pkgID] { throw failure }
        guard let info = infos[pkgID] else { throw PkgutilCommandFailure.unexpectedFailure }
        return info
    }

    func files(pkgID: String) throws -> [String] {
        if let failure = fileFailures[pkgID] { throw failure }
        guard let files = files[pkgID] else { throw PkgutilCommandFailure.unexpectedFailure }
        return files
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
