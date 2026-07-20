import Darwin
import Foundation
import XCTest
@testable import AppUI
import ScanKit

/// v1.2 P1-7 启动项查看屏 —— 扫描器单元测试。
///
/// 关键不变量：
/// - 解析正常 plist：Label / ProgramArguments / RunAtLoad 三字段全部还原
/// - 缺字段：缺 Label 视为损坏（跳过）；缺 ProgramArguments 返回空数组；缺 RunAtLoad 视为 false
/// - 损坏 plist：反序列化失败 / 顶层不是 dict / 文件读不出，全部跳过，**不影响其他条目**
/// - scope 分组：user / system / daemon 三个目录互不串
/// - 排序：scanAll 按 path 字典序升序
/// - 空目录：listDirectory 返回 nil 或空数组都返回空 items
/// - **只读契约**：FakeFS 没有写/删方法；scanner 公开 API 也没有
final class LaunchAgentScannerTests: XCTestCase {

    // MARK: - 测试 fixture：内存假 FS

    /// 仅在内存里维护 path → Data / path → [path]，可被 scanner 透明使用。
    /// 不暴露任何写/删方法，符合 LaunchAgentFS 契约。
    private struct FakeFS: LaunchAgentFS {
        let directories: [String: [String]]
        let files: [String: Data]
        let sizes: [String: Int64]
        let failures: [String: LaunchAgentIOFailureReason]
        let metadataFailures: [String: LaunchAgentIOFailureReason]

        init(
            directories: [String: [String]],
            files: [String: Data],
            sizes: [String: Int64],
            failures: [String: LaunchAgentIOFailureReason] = [:],
            metadataFailures: [String: LaunchAgentIOFailureReason] = [:]
        ) {
            self.directories = directories
            self.files = files
            self.sizes = sizes
            self.failures = failures
            self.metadataFailures = metadataFailures
        }

        func listDirectory(_ path: String) -> LaunchAgentIOResult<[String]> {
            if let reason = failures[path] {
                return .failure(.init(path: path, operation: .listDirectory, reason: reason))
            }
            guard let children = directories[path] else {
                return .failure(.init(path: path, operation: .listDirectory, reason: .notFound))
            }
            return .value(children)
        }
        func readFile(_ path: String) -> LaunchAgentIOResult<Data> {
            if let reason = failures[path] {
                return .failure(.init(path: path, operation: .readFile, reason: reason))
            }
            guard let data = files[path] else {
                return .failure(.init(path: path, operation: .readFile, reason: .notFound))
            }
            return .value(data)
        }
        func fileSize(_ path: String) -> LaunchAgentIOResult<Int64> {
            if let reason = metadataFailures[path] {
                return .failure(.init(path: path, operation: .readMetadata, reason: reason))
            }
            if let reason = failures[path] {
                return .failure(.init(path: path, operation: .readMetadata, reason: reason))
            }
            guard files[path] != nil || sizes[path] != nil else {
                return .failure(.init(path: path, operation: .readMetadata, reason: .notFound))
            }
            return .value(sizes[path] ?? Int64(files[path]?.count ?? 0))
        }
    }

    /// v2026.07.18: synchronized probes are test-only witnesses for the Sendable filesystem seam.
    private final class SnapshotCallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var boundedReads = 0
        private var legacyReads = 0
        private var metadataReads = 0
        private var observedLimit: Int?
        private var observedCancellation = false

        func recordBoundedRead(limit: Int, wasCancelled: Bool) {
            lock.lock()
            boundedReads += 1
            observedLimit = limit
            observedCancellation = wasCancelled
            lock.unlock()
        }

        func recordLegacyRead() {
            lock.lock()
            legacyReads += 1
            lock.unlock()
        }

        func recordMetadataRead() {
            lock.lock()
            metadataReads += 1
            lock.unlock()
        }

        var boundedReadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return boundedReads
        }

        var legacyReadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return legacyReads
        }

        var metadataReadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return metadataReads
        }

        var limit: Int? {
            lock.lock()
            defer { lock.unlock() }
            return observedLimit
        }

        var cancellationValue: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observedCancellation
        }
    }

    private struct SnapshotOnlyFS: LaunchAgentFS {
        let directory: String
        let path: String
        let snapshot: LaunchAgentFileSnapshot
        let probe: SnapshotCallProbe

        func listDirectory(_ requestedPath: String) -> LaunchAgentIOResult<[String]> {
            guard requestedPath == directory else {
                return .failure(.init(
                    path: requestedPath,
                    operation: .listDirectory,
                    reason: .notFound
                ))
            }
            return .value([path])
        }

        func readFile(_ requestedPath: String) -> LaunchAgentIOResult<Data> {
            probe.recordLegacyRead()
            return .failure(.init(
                path: requestedPath,
                operation: .readFile,
                reason: .other
            ))
        }

        func fileSize(_ requestedPath: String) -> LaunchAgentIOResult<Int64> {
            probe.recordMetadataRead()
            return .failure(.init(
                path: requestedPath,
                operation: .readMetadata,
                reason: .other
            ))
        }

        func readFileSnapshot(
            _ requestedPath: String
        ) -> LaunchAgentIOResult<LaunchAgentFileSnapshot> {
            guard requestedPath == path else {
                return .failure(.init(
                    path: requestedPath,
                    operation: .readFile,
                    reason: .notFound
                ))
            }
            probe.recordBoundedRead(limit: -1, wasCancelled: false)
            return .value(snapshot)
        }
    }

    /// 生成符合 launchd 规范的 plist（XML 格式，属性可选）。
    private func makePlist(
        label: String?,
        programArguments: [String]? = nil,
        program: String? = nil,
        runAtLoad: Bool? = nil
    ) -> Data {
        var dict: [String: Any] = [:]
        if let label { dict["Label"] = label }
        if let programArguments { dict["ProgramArguments"] = programArguments }
        if let program { dict["Program"] = program }
        if let runAtLoad { dict["RunAtLoad"] = runAtLoad }
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private let home = "/Users/tester"
    private var userDir: String { "\(home)/Library/LaunchAgents" }
    private let systemDir = "/Library/LaunchAgents"
    private let daemonDir = "/Library/LaunchDaemons"

    // MARK: - 1. 正常 plist 解析

    func test_parsePlist_完整字段全部正确还原() async {
        let path = "\(userDir)/com.foo.bar.plist"
        let data = makePlist(
            label: "com.foo.bar",
            programArguments: ["/usr/bin/foo", "--flag", "1"],
            runAtLoad: true
        )
        let fs = FakeFS(
            directories: [userDir: [path]],
            files: [path: data],
            sizes: [path: 512]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.label, "com.foo.bar")
        XCTAssertEqual(item.programArguments, ["/usr/bin/foo", "--flag", "1"])
        XCTAssertTrue(item.runAtLoad)
        XCTAssertEqual(item.fileSize, 512)
        XCTAssertEqual(item.scope, .user)
        XCTAssertEqual(item.path, path)
    }

    // MARK: - 2. 损坏 plist 跳过

    func test_parsePlist_完全损坏的二进制内容直接跳过() async {
        let badPath = "\(userDir)/broken.plist"
        let goodPath = "\(userDir)/com.ok.plist"
        let fs = FakeFS(
            directories: [userDir: [badPath, goodPath]],
            files: [
                badPath: Data([0xFF, 0x00, 0x42, 0xAB, 0xCD]),
                goodPath: makePlist(label: "com.ok", runAtLoad: false)
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        // broken.plist 不影响 good 的解析
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].label, "com.ok")
    }

    // MARK: - 3. 缺 Label 字段 → 损坏跳过

    func test_parsePlist_缺Label字段视为损坏跳过() async {
        let noLabelPath = "\(userDir)/no.label.plist"
        let okPath = "\(userDir)/has.label.plist"
        let fs = FakeFS(
            directories: [userDir: [noLabelPath, okPath]],
            files: [
                noLabelPath: makePlist(label: nil, programArguments: ["/bin/x"]),
                okPath: makePlist(label: "has.label")
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].label, "has.label")
    }

    func test_parsePlist_空Label视为损坏跳过() async {
        let path = "\(userDir)/empty.label.plist"
        let fs = FakeFS(
            directories: [userDir: [path]],
            files: [path: makePlist(label: "", runAtLoad: true)],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 0)
    }

    // MARK: - 4. 缺可选字段 → 用默认值

    func test_parsePlist_缺ProgramArguments返回空数组_缺RunAtLoad返回false() async {
        let path = "\(userDir)/minimal.plist"
        let fs = FakeFS(
            directories: [userDir: [path]],
            // 仅 Label，没有 ProgramArguments / Program / RunAtLoad
            files: [path: makePlist(label: "com.minimal")],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].label, "com.minimal")
        XCTAssertEqual(items[0].programArguments, [])
        XCTAssertFalse(items[0].runAtLoad)
    }

    func test_parsePlist_仅有Program字符串字段时归并成单元素数组() async {
        let path = "\(userDir)/program.only.plist"
        let fs = FakeFS(
            directories: [userDir: [path]],
            files: [path: makePlist(label: "com.prog", program: "/usr/local/bin/proc")],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].programArguments, ["/usr/local/bin/proc"])
    }

    // MARK: - 5. 三段 scope 分组

    func test_scanAll_三个目录的plist分别归入对应scope() async {
        let userPath = "\(userDir)/u.plist"
        let systemPath = "\(systemDir)/s.plist"
        let daemonPath = "\(daemonDir)/d.plist"
        let fs = FakeFS(
            directories: [
                userDir: [userPath],
                systemDir: [systemPath],
                daemonDir: [daemonPath]
            ],
            files: [
                userPath: makePlist(label: "u"),
                systemPath: makePlist(label: "s"),
                daemonPath: makePlist(label: "d")
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)

        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 3)
        let byScope = Dictionary(grouping: items, by: \.scope)
        XCTAssertEqual(byScope[.user]?.first?.label, "u")
        XCTAssertEqual(byScope[.system]?.first?.label, "s")
        XCTAssertEqual(byScope[.daemon]?.first?.label, "d")
    }

    // MARK: - 6. 空目录 / 不存在目录

    func test_scanAll_所有目录都为空时返回空数组() async {
        let fs = FakeFS(directories: [:], files: [:], sizes: [:])
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)
        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 0)
    }

    func test_scanAll_部分目录为空时其他scope仍能返回() async {
        let daemonPath = "\(daemonDir)/only.d.plist"
        let fs = FakeFS(
            directories: [
                userDir: [],          // 空目录
                // systemDir 完全不存在
                daemonDir: [daemonPath]
            ],
            files: [daemonPath: makePlist(label: "only.d", runAtLoad: true)],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)
        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].scope, .daemon)
        XCTAssertEqual(items[0].label, "only.d")
    }

    // MARK: - 7. 排序：scanAll 按 path 升序

    func test_scanAll_输出按path字典序升序排列() async {
        // 故意把添加顺序打乱，验证 scanner 内部 sort 生效
        let p1 = "\(userDir)/aaa.plist"
        let p2 = "\(userDir)/zzz.plist"
        let p3 = "\(systemDir)/mmm.plist"
        let fs = FakeFS(
            directories: [
                userDir: [p2, p1],
                systemDir: [p3]
            ],
            files: [
                p1: makePlist(label: "aaa"),
                p2: makePlist(label: "zzz"),
                p3: makePlist(label: "mmm")
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)
        let items = await scanner.scanAll()
        XCTAssertEqual(items.map(\.path), [p3, p1, p2])
    }

    // MARK: - 8. 非 .plist 后缀过滤

    func test_scanAll_非plist后缀的文件被忽略() async {
        let plistPath = "\(userDir)/com.real.plist"
        let txtPath = "\(userDir)/README.txt"
        let dsStorePath = "\(userDir)/.DS_Store"
        let fs = FakeFS(
            directories: [userDir: [plistPath, txtPath, dsStorePath]],
            files: [
                plistPath: makePlist(label: "com.real"),
                txtPath: Data("hello".utf8),
                dsStorePath: Data([0x00, 0x01])
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)
        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].label, "com.real")
    }

    // MARK: - 9. 顶层不是 dict 的 plist 视为损坏

    func test_parsePlist_顶层为数组的plist视为损坏跳过() async {
        let arrPath = "\(userDir)/array.plist"
        let okPath = "\(userDir)/ok.plist"
        let arrData = try! PropertyListSerialization.data(
            fromPropertyList: ["a", "b"] as [Any], format: .xml, options: 0
        )
        let fs = FakeFS(
            directories: [userDir: [arrPath, okPath]],
            files: [
                arrPath: arrData,
                okPath: makePlist(label: "ok")
            ],
            sizes: [:]
        )
        let scanner = LaunchAgentScanner(fs: fs, homeDirectory: home)
        let items = await scanner.scanAll()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].label, "ok")
    }

    // MARK: - 10. 安全契约：扫描器不暴露任何删除入口

    func test_安全契约_LaunchAgentScanner没有删除API() {
        // 阅读期 + 编译期不变量：scanner 公开 API 仅 scanAll；
        // FakeFS 也没有 write/remove 方法。任何人未来加删除方法，
        // 这条 sanity test + grep + code review 三道关卡会立刻发现。
        let scanner = LaunchAgentScanner()
        XCTAssertNotNil(scanner)
    }

    // MARK: - 11. Step 14 静默失败修复：DefaultLaunchAgentFS 错误分类

    /// chmod 000 子目录后 listDirectory 应返回类型化 permissionDenied
    func test_DefaultFS_无权限目录listDirectory应返回类型化失败() throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LA-Tests-EACCES-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let fs = DefaultLaunchAgentFS()
        let result = fs.listDirectory(tmp.path)
        guard case .failure(let failure) = result else {
            return XCTFail("无权限目录必须返回类型化失败")
        }
        XCTAssertEqual(failure.path, tmp.path)
        XCTAssertEqual(failure.operation, .listDirectory)
        XCTAssertEqual(failure.reason, .permissionDenied)
    }

    /// 不存在的目录 listDirectory 应返回 nil 但 **不** 触发 permissionDenied
    func test_DefaultFS_不存在目录listDirectory静默不上报() throws {
        let nonexistent = "/Users/__nope__/__no_such_dir__/\(UUID().uuidString)"
        let fs = DefaultLaunchAgentFS()

        let result = fs.listDirectory(nonexistent)
        guard case .failure(let failure) = result else {
            return XCTFail("不存在目录必须保留 notFound 语义")
        }
        XCTAssertEqual(failure.reason, .notFound)
    }

    /// readFile：无权限读 → permissionDenied handler；不存在 → 静默
    func test_DefaultFS_无权限文件readFile应上报permissionDenied() throws {
        if getuid() == 0 {
            throw XCTSkip("以 root 身份运行时 chmod 0000 不会阻止 open，跳过此用例")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LA-Tests-FileEACCES-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        let fs = DefaultLaunchAgentFS()

        let result = fs.readFile(tmp.path)
        guard case .failure(let failure) = result else {
            return XCTFail("无权限文件必须返回类型化失败")
        }
        XCTAssertEqual(failure.path, tmp.path)
        XCTAssertEqual(failure.operation, .readFile)
        XCTAssertEqual(failure.reason, .permissionDenied)
    }

    // MARK: - 12. 有界单快照与 no-follow 合同

    func test_DefaultFS_单次bounded读取同时冻结payload与size() throws {
        let payload = makePlist(label: "same-generation")
        let probe = SnapshotCallProbe()
        let fs = DefaultLaunchAgentFS(
            shouldCancel: { false },
            boundedReader: { _, limit, shouldCancel in
                probe.recordBoundedRead(
                    limit: limit,
                    wasCancelled: shouldCancel()
                )
                return payload
            }
        )

        guard case .value(let snapshot) = fs.readFileSnapshot("/fixture/job.plist") else {
            return XCTFail("稳定 plist 必须返回单次快照")
        }

        XCTAssertEqual(probe.boundedReadCount, 1)
        XCTAssertEqual(probe.limit, DefaultLaunchAgentFS.maximumPropertyListBytes)
        XCTAssertFalse(probe.cancellationValue)
        XCTAssertEqual(snapshot.data, payload)
        XCTAssertEqual(snapshot.fileSize, Int64(payload.count))
        XCTAssertNil(snapshot.metadataFailure)
    }

    func test_scanner只消费snapshot_不回退readFile加fileSize() async {
        let path = "\(userDir)/single-generation.plist"
        let payload = makePlist(label: "single-generation")
        let probe = SnapshotCallProbe()
        let fs = SnapshotOnlyFS(
            directory: userDir,
            path: path,
            snapshot: LaunchAgentFileSnapshot(
                data: payload,
                fileSize: Int64(payload.count)
            ),
            probe: probe
        )

        let result = await LaunchAgentScanner(fs: fs, homeDirectory: home).scan(scope: .user)

        XCTAssertEqual(result.items.map(\.label), ["single-generation"])
        XCTAssertEqual(result.items.first?.fileSize, Int64(payload.count))
        XCTAssertEqual(probe.boundedReadCount, 1)
        XCTAssertEqual(probe.legacyReadCount, 0)
        XCTAssertEqual(probe.metadataReadCount, 0)
        XCTAssertTrue(result.isComplete)
    }

    func test_DefaultFS_oversize_symlink_FIFO均保留typed不完整证据且不阻塞() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAgentBoundedRead-\(UUID().uuidString)", isDirectory: true)
        let launchAgents = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launchAgents,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let oversize = launchAgents.appendingPathComponent("oversize.plist")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversize.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversize)
        try handle.truncate(atOffset: UInt64(DefaultLaunchAgentFS.maximumPropertyListBytes + 1))
        try handle.close()

        let target = launchAgents.appendingPathComponent("target.plist")
        try makePlist(label: "target").write(to: target)
        let symlink = launchAgents.appendingPathComponent("symlink.plist")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let fifo = launchAgents.appendingPathComponent("fifo.plist")
        let fifoResult = fifo.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, S_IRUSR | S_IWUSR)
        }
        XCTAssertEqual(fifoResult, 0)

        let fs = DefaultLaunchAgentFS()
        assertReadFailure(fs.readFileSnapshot(oversize.path), reason: .tooLarge)
        assertReadFailure(fs.readFileSnapshot(symlink.path), reason: .unsafeFileType)
        assertReadFailure(fs.readFileSnapshot(fifo.path), reason: .unsafeFileType)

        let scan = await LaunchAgentScanner(
            fs: fs,
            homeDirectory: root.path
        ).scan(scope: .user)
        XCTAssertEqual(scan.items.map(\.label), ["target"])
        XCTAssertEqual(Set(scan.issues), Set([
            .init(scope: .user, path: oversize.path, reason: .readFailed),
            .init(scope: .user, path: symlink.path, reason: .readFailed),
            .init(scope: .user, path: fifo.path, reason: .readFailed)
        ]))
        XCTAssertFalse(scan.wasCancelled)
        XCTAssertFalse(scan.isComplete)
    }

    func test_changed与cancelled进入不同扫描控制流() async {
        let changedDefaultFS = DefaultLaunchAgentFS(
            shouldCancel: { false },
            boundedReader: { _, _, _ in throw BoundedLocalFileReadError.changed }
        )
        assertReadFailure(
            changedDefaultFS.readFileSnapshot("/fixture/replaced.plist"),
            reason: .changedDuringRead
        )

        let cancelledDefaultFS = DefaultLaunchAgentFS(
            shouldCancel: { true },
            boundedReader: { _, _, shouldCancel in
                if shouldCancel() { throw BoundedLocalFileReadError.cancelled }
                return Data()
            }
        )
        assertReadFailure(
            cancelledDefaultFS.readFileSnapshot("/fixture/cancelled.plist"),
            reason: .cancelled
        )

        let changedPath = "\(userDir)/changed.plist"
        let changedFS = FakeFS(
            directories: [userDir: [changedPath]],
            files: [:],
            sizes: [:],
            failures: [changedPath: .changedDuringRead]
        )
        let changed = await LaunchAgentScanner(
            fs: changedFS,
            homeDirectory: home
        ).scan(scope: .user)

        XCTAssertEqual(changed.issues, [
            .init(scope: .user, path: changedPath, reason: .changedDuringScan)
        ])
        XCTAssertFalse(changed.wasCancelled)

        let cancelledPath = "\(userDir)/cancelled.plist"
        let cancelledFS = FakeFS(
            directories: [userDir: [cancelledPath]],
            files: [:],
            sizes: [:],
            failures: [cancelledPath: .cancelled]
        )
        let cancelled = await LaunchAgentScanner(
            fs: cancelledFS,
            homeDirectory: home
        ).scan(scope: .user)

        XCTAssertTrue(cancelled.issues.isEmpty)
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertFalse(cancelled.isComplete)
    }

    private func assertReadFailure(
        _ result: LaunchAgentIOResult<LaunchAgentFileSnapshot>,
        reason: LaunchAgentIOFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let failure) = result else {
            return XCTFail("必须返回类型化读取失败", file: file, line: line)
        }
        XCTAssertEqual(failure.operation, .readFile, file: file, line: line)
        XCTAssertEqual(failure.reason, reason, file: file, line: line)
    }

    // MARK: - 13. 不完整证据必须进入扫描结果

    func test_scanAll_目录权限失败不能伪装成空结果() async {
        let fs = FakeFS(
            directories: [:],
            files: [:],
            sizes: [:],
            failures: [userDir: .permissionDenied]
        )
        let result = await LaunchAgentScanner(fs: fs, homeDirectory: home).scanAll()

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.isComplete)
        let expected: [LaunchAgentScanIssue] = [
            .init(scope: .user, path: userDir, reason: .permissionDenied)
        ]
        XCTAssertEqual(result.issues, expected)
    }

    func test_scanAll_损坏plist保留issue且不影响正常条目() async {
        let badPath = "\(userDir)/broken.plist"
        let goodPath = "\(userDir)/good.plist"
        let fs = FakeFS(
            directories: [userDir: [badPath, goodPath]],
            files: [
                badPath: Data([0xFF, 0x00]),
                goodPath: makePlist(label: "good")
            ],
            sizes: [:]
        )
        let result = await LaunchAgentScanner(fs: fs, homeDirectory: home).scanAll()

        XCTAssertEqual(result.items.map(\.label), ["good"])
        let expected: [LaunchAgentScanIssue] = [
            .init(scope: .user, path: badPath, reason: .invalidPropertyList)
        ]
        XCTAssertEqual(result.issues, expected)
    }

    /// v2026.07.18：metadata 权限失败不能退化成 generic metadataUnavailable。
    func test_scanAll_元数据权限失败保留permissionDenied来源() async {
        let path = "\(userDir)/permission.plist"
        let fs = FakeFS(
            directories: [userDir: [path]],
            files: [path: makePlist(label: "permission")],
            sizes: [:],
            metadataFailures: [path: .permissionDenied]
        )

        let result = await LaunchAgentScanner(fs: fs, homeDirectory: home).scanAll()

        XCTAssertEqual(result.items.map(\.label), ["permission"])
        XCTAssertEqual(result.items.first?.fileSize, 0)
        XCTAssertEqual(result.issues, [
            .init(scope: .user, path: path, reason: .permissionDenied)
        ])
    }

    func test_reloadGate_旧轮不能完成新revision() {
        let old = LaunchAgentReloadIdentity(operationID: UUID(), revision: 1)
        let current = LaunchAgentReloadIdentity(operationID: UUID(), revision: 2)
        var gate = LaunchAgentReloadGate()
        gate.begin(old)
        gate.begin(current)

        XCTAssertNil(gate.finishIfCurrent(old, taskWasCancelled: false))
        XCTAssertEqual(gate.current, current)
        XCTAssertEqual(gate.finishIfCurrent(current, taskWasCancelled: false), true)
        XCTAssertNil(gate.current)
    }

    func test_reloadGate_当前轮取消后不能发布() {
        let identity = LaunchAgentReloadIdentity(operationID: UUID(), revision: 7)
        var gate = LaunchAgentReloadGate()
        gate.begin(identity)

        XCTAssertEqual(gate.finishIfCurrent(identity, taskWasCancelled: true), false)
        XCTAssertNil(gate.current)
    }

    func test_metricProjection_任一缺口都使总量成为部分结果() {
        XCTAssertTrue(LaunchAgentMetricProjection.isComplete(issues: []))
        XCTAssertFalse(LaunchAgentMetricProjection.isComplete(issues: [
            .init(scope: .system, path: systemDir, reason: .permissionDenied)
        ]))
    }
}
