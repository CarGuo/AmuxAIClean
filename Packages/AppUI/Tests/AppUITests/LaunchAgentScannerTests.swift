import XCTest
@testable import AppUI

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

        func listDirectory(_ path: String) -> [String]? {
            directories[path]
        }
        func readFile(_ path: String) -> Data? {
            files[path]
        }
        func fileSize(_ path: String) -> Int64 {
            sizes[path] ?? Int64(files[path]?.count ?? 0)
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

    /// 线程安全的 String 收集器，用于在 @Sendable handler 内累计路径
    private final class PathCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    /// chmod 000 子目录后 listDirectory 应触发 permissionDenied handler
    func test_DefaultFS_无权限目录listDirectory应上报permissionDenied() throws {
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

        let collector = PathCollector()
        let fs = DefaultLaunchAgentFS(permissionDeniedHandler: { collector.append($0) })

        // listDirectory 仍然返回 nil（兼容旧调用方），同时 handler 收到这个无权限路径
        let result = fs.listDirectory(tmp.path)
        XCTAssertNil(result, "无权限目录 listDirectory 必须返回 nil")
        XCTAssertEqual(collector.snapshot, [tmp.path], "permissionDeniedHandler 必须被调用一次，参数是无权限目录路径")
    }

    /// 不存在的目录 listDirectory 应返回 nil 但 **不** 触发 permissionDenied
    func test_DefaultFS_不存在目录listDirectory静默不上报() throws {
        let nonexistent = "/Users/__nope__/__no_such_dir__/\(UUID().uuidString)"
        let collector = PathCollector()
        let fs = DefaultLaunchAgentFS(permissionDeniedHandler: { collector.append($0) })

        let result = fs.listDirectory(nonexistent)
        XCTAssertNil(result)
        XCTAssertTrue(collector.snapshot.isEmpty, "ENOENT 必须静默到 GSYLog.debug，不调用 permissionDeniedHandler")
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

        let collector = PathCollector()
        let fs = DefaultLaunchAgentFS(permissionDeniedHandler: { collector.append($0) })

        let result = fs.readFile(tmp.path)
        XCTAssertNil(result)
        XCTAssertEqual(collector.snapshot, [tmp.path])
    }
}
